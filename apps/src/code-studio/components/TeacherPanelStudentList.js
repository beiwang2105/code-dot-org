import React, { PropTypes } from 'react';
import { connect } from 'react-redux';
import FontAwesome from '@cdo/apps/templates/FontAwesome';

const styles = {
  main: {
  }
};

const StudentEntry = (props) => {
  const { isActive, status, isUnplugged, position, isPairing, isNavigator, name, id } = props;

  const path = `${window.location.href}&user_id=${id}`;

  let statusIcon;
  if (isUnplugged) {
    statusIcon = <span className="puzzle-named">Unplugged</span>;
  } else if (status === "passed" || status === "perfect") {
    // TODO: have server pass this down?
    statusIcon = (
      <img
        src="https://studio.code.org/assets/white-checkmark-f80a03318e57c26afca1a6e50c5973da929daf81a694b1783d3017df5875c712.png"
        alt="White checkmark"
      />
    );
  } else {
    statusIcon = (
      <span className="puzzle-number">
        {position}
      </span>
    );
  }

  return (
    <tr className={'section-student' + (isActive ? ' active' : '')}>
      <td>
        <div className={"level_link " + status}>
          {statusIcon}
        </div>
      </td>
      <td className={'name' + (isNavigator ? ' navigator' : '')}>
        <a href={path}>
          {name}
          {isPairing && <FontAwesome icon="users" className="pair-programming-icon"/>}
        </a>
      </td>
    </tr>
  );
};
StudentEntry.propTypes = {
  isActive: PropTypes.bool.isRequired,
  status: PropTypes.string.isRequired,
  isUnplugged: PropTypes.bool.isRequired,
  position: PropTypes.number.isRequired,
  isNavigator: PropTypes.bool.isRequired,
  isPairing: PropTypes.bool.isRequired,
  name: PropTypes.string.isRequired,
  id: PropTypes.number.isRequired
};

const TeacherPanelStudentList = React.createClass({
  propTypes: {
    studentInfo: PropTypes.object.isRequired,
    sectionId: PropTypes.string.isRequired,
    activeUserId: PropTypes.string
  },
  render() {
    const { studentInfo, activeUserId, sectionId } = this.props;

    const sectionStudentInfo = studentInfo[sectionId] || [];
    return (
      <div className="scrollable-wrapper" style={styles.main}>
        <table className="section-students">
          <tbody>
            {sectionStudentInfo.map((student, index) => {
              const { name, id, status, unplugged, position, pairing, navigator, path }  = student;
              return (
                <StudentEntry
                  key={index}
                  name={name}
                  id={id}
                  path={path}
                  isActive={activeUserId !== undefined && activeUserId === id}
                  isUnplugged={unplugged}
                  status={status}
                  position={position}
                  isPairing={!!pairing}
                  isNavigator={!!navigator}
                />
              );
            })}
          </tbody>
        </table>
      </div>
    );
  }
});

export default connect(state => ({
  sectionId: state.sections.selectedSectionId
}))(TeacherPanelStudentList);
