<?php
session_start();
require_once __DIR__ . '/config.php';

// Allow student or update-admin
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

$userId = $_SESSION['user_id'];
$cart = $_SESSION['cart'] ?? [];

if (empty($cart)) {
    die("Your cart is empty.");
}

$mysqli = get_db();
$mysqli->set_charset('utf8mb4');

// Prepare statements
$check = $mysqli->prepare("
    SELECT 1 
    FROM StudentEnrollment 
    WHERE StudentID = ? 
      AND CRN = ? 
      AND Status IN ('ENROLLED','IN-PROGRESS','PLANNED','WAITLIST')
");

$getCourse = $mysqli->prepare("
    SELECT SemesterID, CourseID, AvailableSeats 
    FROM CourseSection 
    WHERE CRN = ?
");

$insertEnroll = $mysqli->prepare("
    INSERT INTO StudentEnrollment (StudentID, SemesterID, CRN, CourseID, Status, EnrollmentDate)
    VALUES (?, ?, ?, ?, ?, CURRENT_DATE())
    ON DUPLICATE KEY UPDATE 
        Status = VALUES(Status),
        EnrollmentDate = VALUES(EnrollmentDate)
");

$checkPrior = $mysqli->prepare("
    SELECT 1
    FROM StudentEnrollment
    WHERE StudentID = ?
      AND CourseID = ?
      AND Status = 'COMPLETED'
      AND Grade IN ('A', 'A-', 'B+', 'B', 'B-', 'C+', 'C')
    LIMIT 1
");

$missingPrereq = $mysqli->prepare("
    SELECT 
        cp.PrerequisiteCourseID,
        cp.MinGradeRequired
    FROM CoursePrerequisite cp
    LEFT JOIN StudentEnrollment sh
        ON sh.StudentID = ?
       AND sh.CourseID = cp.PrerequisiteCourseID
       AND sh.Status = 'COMPLETED'
    LEFT JOIN GradingScale gs_req 
        ON gs_req.GradeLetter = cp.MinGradeRequired
    LEFT JOIN GradingScale gs_got 
        ON gs_got.GradeLetter = sh.Grade
    WHERE cp.CourseID = ?
      AND (
            sh.Grade IS NULL 
         OR gs_got.GradeValue < gs_req.GradeValue
      )
");

$enrolled = [];
$waitlisted = [];
$errors = [];

foreach ($cart as $item) {

    $crn = is_array($item) ? ($item['crn'] ?? null) : $item;
    $courseIdFromCart = is_array($item) ? ($item['courseID'] ?? null) : '';

    if (empty($crn) || !is_numeric($crn)) continue;

    // Prevent duplicate enrollment
    $check->bind_param('ii', $userId, $crn);
    $check->execute();
    $check->store_result();

    if ($check->num_rows > 0) {
        continue; // already enrolled or planned
    }

    // Lookup course data
    $getCourse->bind_param('i', $crn);
    $getCourse->execute();
    $course = $getCourse->get_result()->fetch_assoc();

    if (!$course) {
        $errors[] = "CRN $crn: Course not found.";
        continue;
    }

    $semesterId = $course['SemesterID'];
    $courseId = $courseIdFromCart ?: $course['CourseID'];
    $available = (int)$course['AvailableSeats'];

    $missingPrereq->bind_param('is', $userId, $courseId);
    $missingPrereq->execute();
    $missingRes = $missingPrereq->get_result();

    if ($missingRes->num_rows > 0) {
        $missingList = [];
        while ($row = $missingRes->fetch_assoc()) {
            $missingList[] = $row['PrerequisiteCourseID'] . " (min " . $row['MinGradeRequired'] . ")";
        }
        $errors[] = "CRN $crn: missing prerequisites: " . implode(', ', $missingList);
        continue;
    }

    $checkPrior->bind_param('ii', $userId, $courseId);
    $checkPrior->execute();
    $checkPrior->store_result();

    if ($checkPrior->num_rows > 0) {
        $errors[] = "CRN $crn: You have already completed this course with a grade of C or better.";
        continue;
    }

    // Determine status first
    if ($available > 0) {
        $status = 'ENROLLED';
    } else {
        $status = 'WAITLIST';
    }

    try {
        // Insert or update enrollment
        $insertEnroll->bind_param('isiss', $userId, $semesterId, $crn, $courseId, $status);
        $insertEnroll->execute();

        /* The seat count is no longer adjusted here. Migration 012 gives
           StudentEnrollment an AFTER INSERT trigger that decrements it in
           the same statement as the insert, which is what makes it safe:
           this code read the count, decided a status, inserted and then
           decremented as a separate statement, so two students registering
           at the same moment could both be handed the last chair. Doing it
           here as well would now charge two seats for one registration. */
        if ($status === 'ENROLLED') {
            $enrolled[] = $crn;
        } else {
            $waitlisted[] = $crn;
        }

    } catch (mysqli_sql_exception $e) {
        $errors[] = "CRN {$crn}: " . $e->getMessage();
        continue;
    }
}

// Close statements
$check->close();
$getCourse->close();
$insertEnroll->close();
$checkPrior->close();
$missingPrereq->close();
unset($_SESSION['cart']);

// Redirect dashboard
$userRole = strtolower($_SESSION['role'] ?? '');
switch ($userRole) {
    case 'student':  $dashboard = 'student_dashboard.php'; break;
    case 'faculty':  $dashboard = 'faculty_dashboard.php'; break;
    case 'admin':
        $dashboard = (($_SESSION['admin_type'] ?? '') === 'update')
                     ? 'update_admin_dashboard.php'
                     : 'view_admin_dashboard.php';
        break;
    case 'statstaff': $dashboard = 'statstaff_dashboard.php'; break;
    default: $dashboard = 'login.html';
}
?>
<!DOCTYPE html>
<html lang="en">
<?php $nu_title = 'Enrollment Confirmation'; require __DIR__ . '/partials/head.php'; ?>
<body>
  <div class="card">
    <h2>Enrollment Summary</h2>

    <?php if (!empty($errors)): ?>
      <div class="error-box">
        <strong>Errors:</strong>
        <ul>
          <?php foreach ($errors as $err): ?>
            <li><?= htmlspecialchars($err) ?></li>
          <?php endforeach; ?>
        </ul>
      </div>
    <?php endif; ?>

    <?php if (!empty($enrolled)): ?>
      <p><strong>Successfully Enrolled:</strong></p>
      <ul>
        <?php foreach ($enrolled as $crn): ?>
          <li>CRN <?= htmlspecialchars($crn) ?></li>
        <?php endforeach; ?>
      </ul>
    <?php endif; ?>

    <?php if (!empty($waitlisted)): ?>
      <p><strong>Waitlisted:</strong></p>
      <ul>
        <?php foreach ($waitlisted as $crn): ?>
          <li>CRN <?= htmlspecialchars($crn) ?></li>
        <?php endforeach; ?>
      </ul>
    <?php endif; ?>

    <?php if (empty($enrolled) && empty($waitlisted) && empty($errors)): ?>
      <p>No enrollment changes were made.</p>
    <?php endif; ?>

    <a href="<?= htmlspecialchars($dashboard) ?>">← Back to Dashboard</a>
  </div>
</body>
</html>