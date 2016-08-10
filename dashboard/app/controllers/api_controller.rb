class ApiController < ApplicationController
  layout false
  include LevelsHelper

  def user_menu
    @show_pairing_dialog = !!session.delete(:show_pairing_dialog)
    render partial: 'shared/user_header'
  end

  def user_hero
    head :not_found unless current_user
  end

  # TODO: what's to prevent a malicious entity from adding an arbitrarily large number of these
  def update_lockable_state
    updates = params.require(:updates)
    updates.to_a.each do |item|
      user_level_data = item[:user_level_data]

      # TODO: maybe we validate that user_id is a student of current_user
      if user_level_data[:user_id].nil? || user_level_data[:level_id].nil? || user_level_data[:script_id].nil?
        raise 'Must provide user, level, and script ids'
      end

      if item[:locked] && item[:view_answers]
        raise 'Can not view answers while locked'
      end

      user_level = UserLevel.find_by(
        user_id: user_level_data[:user_id],
        level_id: user_level_data[:level_id],
        script_id: user_level_data[:script_id],
      )
      # no need to create a level if it's just going to be locked
      next if !user_level && item[:locked]

      user_level ||= UserLevel.create(
        user_id: user_level_data[:user_id],
        level_id: user_level_data[:level_id],
        script_id: user_level_data[:script_id]
      )

      user_level.update!(
        submitted: item[:locked],
        view_answers: !item[:locked] && item[:view_answers],
        unlocked_at: item[:locked] ? nil : Time.now
      )
    end
    render json: {}
  end

  # For a given users, gets the lockable state for each user in each of their sections
  def lockable_state
    return unless current_user

    data = current_user.sections.each_with_object({}) do |section, section_hash|
      next if section[:deleted_at]
      @section = section
      load_script
      section_hash[section.id] = {
        section_id: section.id,
        section_name: section.name,
        stages: @script.stages.each_with_object({}) do |stage, stage_hash|
          next unless stage.lockable?
          # assumption that lockable stages have a single (assessment) level
          # TODO: test this error condition
          if stage.script_levels.length > 1
            raise 'Expect lockable stages to have a single script_level'
          end
          script_level = stage.script_levels[0]
          stage_hash[stage.id] = section.students.map do |student|
            user_level = UserLevel.find_by(user_id: student.id, level: script_level.level, script_id:  @script.id)
            # user_level_data is provided so that we can get back to our user_level when updating. in some cases we
            # don't yet have a user_level, and need to provide enough data to create one
            {
              user_level_data: {
                user_id: student.id,
                level_id: script_level.level.id,
                script_id: script_level.script.id
              },
              name: student.name,
              # if we don't have a user level, consider ourselves locked
              locked: user_level ? user_level.locked? : true,
              view_answers: user_level ? !user_level.locked? && user_level.view_answers? : false
            }
          end
        end
      }
    end

    render json: data
  end

  def section_progress
    load_section
    load_script

    # stage data
    stages = @script.script_levels.group_by(&:stage).map do |stage, levels|
      {length: levels.length,
       title: ActionController::Base.helpers.strip_tags(stage.localized_title)}
    end

    # student level completion data
    students = @section.students.map do |student|
      level_map = student.user_levels_by_level(@script)
      student_levels = @script.script_levels.map do |script_level|
        user_levels = script_level.level_ids.map{|id| level_map[id]}.compact
        level_class = best_activity_css_class user_levels
        paired = user_levels.any?(&:paired?)
        level_class << ' paired' if paired
        title = paired ? '' : script_level.position
        {class: level_class, title: title, url: build_script_level_url(script_level, section_id: @section.id, user_id: student.id)}
      end
      {id: student.id, levels: student_levels}
    end

    data = {
            students: students,
            script: {
                     id: @script.id,
                     name: data_t_suffix('script.name', @script.name, 'title'),
                     levels_count: @script.script_levels.length,
                     stages: stages
                    }
           }

    render json: data
  end

  def student_progress
    load_student
    load_section
    load_script

    progress_html = render_to_string(partial: 'shared/user_stats', locals: {user: @student})

    data = {
      student: {
        id: @student.id,
        name: @student.name,
      },
      script: {
        id: @script.id,
        name: @script.localized_title
      },
      progressHtml: progress_html
    }

    render json: data
  end

  def script_structure
    script = Script.get_from_cache(params[:script_name])
    render json: script.summarize
  end

  # Return a JSON summary of the user's progress across all scripts.
  def user_progress_for_all_scripts
    user = current_user
    if user
      render json: summarize_user_progress_for_all_scripts(user)
    else
      render json: {}
    end
  end

  # Return a JSON summary of the user's progress for params[:script_name].
  def user_progress
    if current_user
      script = Script.get_from_cache(params[:script_name])
      user = params[:user_id] ? User.find(params[:user_id]) : current_user
      render json: summarize_user_progress(script, user)
    else
      render json: {}
    end
  end

  # Return the JSON details of the users progress on a particular script
  # level and marks the user as having started that level. (Because of the
  # latter side effect, this should only be called when the user sees the level,
  # to avoid spurious activity monitor warnings about the level being started
  # but not completed.)
  def user_progress_for_stage
    response = {}

    script = Script.get_from_cache(params[:script_name])
    stage = script.stages[params[:stage_position].to_i - 1]
    script_level = stage.script_levels[params[:level_position].to_i - 1]
    level = params[:level] ? Script.cache_find_level(params[:level].to_i) : script_level.oldest_active_level

    if current_user
      last_activity = current_user.last_attempt(level)
      level_source = last_activity.try(:level_source).try(:data)

      response[:progress] = current_user.user_progress_by_stage(stage)
      if last_activity
        response[:lastAttempt] = {
          timestamp: last_activity.updated_at.to_datetime.to_milliseconds,
          source: level_source
        }
      end
      response[:disableSocialShare] = current_user.under_13?
      response[:disablePostMilestone] =
        !Gatekeeper.allows('postMilestone', where: {script_name: script.name}, default: true)

      recent_driver = UserLevel.most_recent_driver(script, level, current_user)
      if recent_driver
        response[:pairingDriver] = recent_driver
      end
    end

    slog(tag: 'activity_start',
         script_level_id: script_level.id,
         level_id: level.id,
         user_agent: request.user_agent,
         locale: locale) if level.finishable?

    render json: response
  end

  def section_text_responses
    load_section
    load_script

    text_response_script_levels = @script.script_levels.includes(:levels).where('levels.type' => [TextMatch, FreeResponse])

    data = @section.students.map do |student|
      student_hash = {id: student.id, name: student.name}

      text_response_script_levels.map do |script_level|
        last_attempt = student.last_attempt(script_level.level)
        response = last_attempt.try(:level_source).try(:data)
        next unless response
        {
          student: student_hash,
          stage: script_level.stage.localized_title,
          puzzle: script_level.position,
          question: script_level.level.properties['title'],
          response: response,
          url: build_script_level_url(script_level, section_id: @section.id, user_id: student.id)
        }
      end.compact
    end.flatten

    render json: data
  end

  # For each student, return an array of each long-assessment LevelGroup in progress or submitted.
  # Each such array contains an array of individual level results, matching the order of the LevelGroup's
  # levels.  For each level, the student's answer content is in :student_result, and its correctness
  # is in :correct.
  def section_assessments
    load_section
    load_script

    level_group_script_levels = @script.script_levels.includes(:levels).where('levels.type' => LevelGroup)

    data = @section.students.map do |student|
      student_hash = {id: student.id, name: student.name}

      level_group_script_levels.map do |script_level|
        next unless script_level.long_assessment?

        # Don't allow somebody to peek inside an anonymous survey using this API.
        next if script_level.anonymous?

        last_attempt = student.last_attempt(script_level.level)
        response = last_attempt.try(:level_source).try(:data)

        next unless response

        response_parsed = JSON.parse(response)

        user_level = student.user_level_for(script_level, script_level.level)

        # Summarize some key data.
        multi_count = 0
        multi_count_correct = 0

        # And construct a listing of all the individual levels and their results.
        level_results = []

        script_level.level.levels.each do |level|
          if level.is_a? Multi
            multi_count += 1
          end

          level_response = response_parsed[level.id.to_s]

          level_result = {}

          if level_response
            case level
            when TextMatch, FreeResponse
              student_result = level_response["result"]
              level_result[:student_result] = student_result
              level_result[:correct] = "free_response"
            when Multi
              answer_indexes = Multi.find_by_id(level.id).correct_answer_indexes
              student_result = level_response["result"].split(",").sort.join(",")

              # Convert "0,1,3" to "A, B, D" for teacher-friendly viewing
              level_result[:student_result] = student_result.split(',').map{ |k| Multi.value_to_letter(k.to_i) }.join(', ')

              if student_result == "-1"
                level_result[:student_result] = ""
                level_result[:correct] = "unsubmitted"
              elsif student_result == answer_indexes
                multi_count_correct += 1
                level_result[:correct] = "correct"
              else
                level_result[:correct] = "incorrect"
              end
            end
          else
            level_result[:correct] = "unsubmitted"
          end

          level_results << level_result
        end

        submitted = user_level.try(:submitted)

        timestamp = user_level[:updated_at].to_formatted_s

        {
          student: student_hash,
          stage: script_level.stage.localized_title,
          puzzle: script_level.position,
          question: script_level.level.properties["title"],
          url: build_script_level_url(script_level, section_id: @section.id, user_id: student.id),
          multi_correct: multi_count_correct,
          multi_count: multi_count,
          submitted: submitted,
          timestamp: timestamp,
          level_results: level_results
        }
      end.compact
    end.flatten

    render json: data
  end

  # Return results for surveys, which are long-assessment LevelGroup levels with the anonymous property.
  # At least five students in the section must have submitted answers.  The answers for each contained
  # sublevel are shuffled randomly.
  def section_surveys
    load_section
    load_script

    render json: LevelGroup.get_survey_results(@script, @section)
  end

  private

  def load_student
    @student = User.find(params[:student_id])
    authorize! :read, @student
  end

  def load_section
    @section = Section.find(params[:section_id])
    authorize! :read, @section
  end

  def load_script
    @script = Script.find(params[:script_id]) if params[:script_id].present?
    @script ||= @section.script || Script.twenty_hour_script
  end
end
