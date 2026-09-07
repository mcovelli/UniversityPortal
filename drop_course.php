<?php
session_start();
require_once __DIR__ . '/config.php';

// Ensure only logged-in students or update-admins can access
if (
    !isset($_SESSION['user_id']) ||
    (
        ($_SESSION['role'] ?? '') !== 'student' &&
        !(($_SESSION['role'] ?? '') === 'admin' && ($_SESSION['admin_type'] ?? '') === 'update')
    )
) {
    header('Location: login.php');
    exit;
}

$mysqli = get_db();
$mysqli->set_charset('utf8mb4');

$userId  = $_SESSION['user_id'];
$crn     = $_POST['crn']     ?? '';
$semester = $_POST['semester'] ?? '';
$dept     = $_POST['dept']     ?? '';

if (empty($crn) || empty($semester)) {
    $_SESSION['error_message'] = "Invalid request. Missing CRN or semester.";
    header('Location: Add_Drop_courses.php');
    exit;
}

try {
    $mysqli->begin_transaction();

    // Verify enrollment
    $check = $mysqli->prepare("
        SELECT 1 FROM StudentEnrollment 
        WHERE StudentID = ? AND CRN = ? AND SemesterID = ?
    ");
    $check->bind_param('iis', $userId, $crn, $semester);
    $check->execute();
    $check->store_result();

    if ($check->num_rows === 0) {
        $check->close();
        $mysqli->rollback();
        $_SESSION['error_message'] = "You are not enrolled in this course.";
        header("Location: Add_Drop_courses.php?Semester=" . urlencode($semester) . "&dept=" . urlencode($dept));
        exit;
    }
    $check->close();

    // Perform drop
    $drop = $mysqli->prepare("
        UPDATE StudentEnrollment 
        SET Status = 'DROPPED'
        WHERE StudentID = ? 
          AND CRN = ? 
          AND SemesterID = ?
          AND Status IN ('ENROLLED','IN-PROGRESS','PLANNED','WAITLIST')
    ");
    $drop->bind_param('iis', $userId, $crn, $semester);
    $drop->execute();

    /* The StudentEnrollment row above is the drop -- there is no second
       table to clean up. The DELETE that used to sit here was also unsafe:
       it matched on StudentID and CRN with no semester, so dropping a
       section this term removed the completed record of the same CRN taken
       in an earlier one. */

    if ($drop->affected_rows > 0) {

        /* The seat is returned by trg_SE_after_update_seats (migration 012),
           in the same statement as the status change. The "+ 1" that used to
           sit here would now return the seat twice, and it had no ceiling --
           repeated drops could inflate a section past its real capacity. */

        $_SESSION['success_message'] = "Successfully dropped course CRN $crn.";
    } else {
        $_SESSION['error_message'] = "Course was already dropped or could not be processed.";
    }

    $mysqli->commit();

} catch (Throwable $e) {
    $mysqli->rollback();
    $_SESSION['error_message'] = "Drop failed: " . $e->getMessage();
}
    
// Redirect back to Add/Drop view
$redirectUrl = "Add_Drop_courses.php";
$q = [];
if (!empty($semester)) $q[] = "Semester=" . urlencode($semester);
if (!empty($dept))     $q[] = "dept=" . urlencode($dept);
if ($q) $redirectUrl .= '?' . implode('&', $q);

header("Location: $redirectUrl");
exit;
?>