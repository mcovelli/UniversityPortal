<?php
session_start();
require_once __DIR__ . '/config.php';
ini_set('display_errors', 1);
error_reporting(E_ALL);

if (!isset($_SESSION['user_id']) || ($_SESSION['role'] ?? '') !== 'admin') {
    redirect(PROJECT_ROOT . "/login.html");
}

$mysqli = get_db();
$mysqli->set_charset('utf8mb4');

// Fetch admin security type
$adminCheck = $mysqli->prepare("
    SELECT SecurityType 
    FROM Admin 
    WHERE AdminID = ? LIMIT 1
");
$adminCheck->bind_param("i", $_SESSION['user_id']);
$adminCheck->execute();
$adminType = $adminCheck->get_result()->fetch_assoc()['SecurityType'] ?? null;
$adminCheck->close();

if ($adminType !== 'UPDATE') {
    die("<h2 style='color:red;'>Access Denied: You are not an UpdateAdmin.</h2>");
}

function loadMajors($mysqli) {
    $res = $mysqli->query("SELECT MajorID, MajorName FROM Major WHERE Status = 'ACTIVE' ORDER BY MajorName");
    return $res->fetch_all(MYSQLI_ASSOC);
}

function loadMinors($mysqli) {
    $res = $mysqli->query("SELECT MinorID, MinorName FROM Minor WHERE Status = 'ACTIVE' ORDER BY MinorName");
    return $res->fetch_all(MYSQLI_ASSOC);
}

function loadPrograms($mysqli) {
    $res = $mysqli->query("SELECT ProgramID, ProgramName FROM Program ORDER BY ProgramName");
    return $res->fetch_all(MYSQLI_ASSOC);
}

function loadDepartments($mysqli) {
    $res = $mysqli->query("SELECT DeptID, DeptName FROM Department ORDER BY DeptName");
    return $res->fetch_all(MYSQLI_ASSOC);
}

function loadOffices($mysqli) {
    $res = $mysqli->query("SELECT RoomID FROM Room WHERE RoomType = 'Office' ORDER BY RoomID ");
    return $res->fetch_all(MYSQLI_ASSOC);
}

$loadedUser = null;
$studentData = null;
$facultyData = null;
$adminData = null;
$statData = null;
$facultyDepartments = [];

if (isset($_POST['searchUser'])) {
    $searchId = intval($_POST['searchID']);

    // Load Users table
    $stmt = $mysqli->prepare("SELECT * FROM Users WHERE UserID = ?");
    $stmt->bind_param("i", $searchId);
    $stmt->execute();
    $loadedUser = $stmt->get_result()->fetch_assoc();
    $stmt->close();

    if ($loadedUser) {
        $role = $loadedUser['UserType'];

        /** Load Student Data **/
        if ($role === 'Student') {
            $q = $mysqli->prepare("SELECT * FROM Student WHERE StudentID = ?");
            $q->bind_param("i", $searchId);
            $q->execute();
            $studentData = $q->get_result()->fetch_assoc();
            $q->close();

            // Undergraduate or Graduate sub-tables
            if ($studentData['StudentType'] === 'Undergraduate') {
                $q = $mysqli->prepare("SELECT * FROM Undergraduate WHERE StudentID = ?");
                $q->bind_param("i", $searchId);
                $q->execute();
                $studentUG = $q->get_result()->fetch_assoc();
                $q->close();
                $studentData['UG'] = $studentUG;
            } else {
                $q = $mysqli->prepare("SELECT * FROM Graduate WHERE StudentID = ?");
                $q->bind_param("i", $searchId);
                $q->execute();
                $studentGrad = $q->get_result()->fetch_assoc();
                $q->close();
                $studentData['GR'] = $studentGrad;
            }
        }

        /** Load Faculty Data **/
        if ($role === 'Faculty') {
            $q = $mysqli->prepare("SELECT * FROM Faculty WHERE FacultyID = ?");
            $q->bind_param("i", $searchId);
            $q->execute();
            $facultyData = $q->get_result()->fetch_assoc();
            $q->close();

            // Load multiple departments
            $dep = $mysqli->prepare("SELECT DeptID FROM Faculty_Dept WHERE FacultyID = ?");
            $dep->bind_param("i", $searchId);
            $dep->execute();
            $facultyDepartments = array_column($dep->get_result()->fetch_all(MYSQLI_ASSOC), 'DeptID');
            $dep->close();
        }

        /** Load Admin Data **/
        if ($role === 'Admin') {
            $q = $mysqli->prepare("SELECT * FROM Admin WHERE AdminID = ?");
            $q->bind_param("i", $searchId);
            $q->execute();
            $adminData = $q->get_result()->fetch_assoc();
            $q->close();
        }

        /** Load StatStaff Data **/
        if ($role === 'StatStaff') {
            $q = $mysqli->prepare("SELECT * FROM StatStaff WHERE StatStaffID = ?");
            $q->bind_param("i", $searchId);
            $q->execute();
            $statData = $q->get_result()->fetch_assoc();
            $q->close();
        }
    }
}

if (isset($_POST['updateUser'])) {

    $uid = intval($_POST['UserID']); // READ ONLY FIELD
    $role = $_POST['UserType'];      // READ ONLY FIELD

    $mysqli->begin_transaction();

    try {

      $status = strtoupper(trim($_POST['Status']));
      if (!in_array($status, ['ACTIVE', 'INACTIVE'])) {
          die("Invalid status value: $status");
      }

        /* ----------------------
           UPDATE USERS TABLE
        ----------------------- */
        $sql = "UPDATE Users 
                SET FirstName=?, MiddleName=?, LastName=?, HouseNumber=?, Street=?, City=?, State=?, ZIP=?, Gender=?, DOB=?, PhoneNumber=?, Status=?
                WHERE UserID=?";
        $stmt = $mysqli->prepare($sql);
        $stmt->bind_param(
            "sssissssssssi",
            $_POST['FirstName'],
            $_POST['MiddleName'],
            $_POST['LastName'],
            $_POST['HouseNumber'],
            $_POST['Street'],
            $_POST['City'],
            $_POST['State'],
            $_POST['ZIP'],
            $_POST['Gender'],
            $_POST['DOB'],
            $_POST['PhoneNumber'],
            $status,
  
            $uid
        );
        $stmt->execute();
        $stmt->close();

        /* ----------------------
           STUDENT UPDATE
        ----------------------- */
        if ($role === 'Student') {

            /* The order below is load-bearing, and it is the reverse of what
               this block used to do. Two rules from migrations 010 and 011
               reject the old sequence outright:

                 - Student.StudentType cannot move while the row for the old
                   type still exists, so the DELETE comes first.
                 - Student.MajorID follows StudentMajor rather than leading
                   it, so the declarations are written last and the sync
                   trigger sets the cached column. Writing MajorID here is
                   what put the two records out of step for 1,152 students
                   in the first place, so this no longer writes it at all. */

            // 1. Drop the subtype row we are moving away from.
            if ($_POST['StudentType'] === "Undergraduate") {
                $mysqli->query("DELETE FROM Graduate WHERE StudentID = $uid");
            } else {
                $mysqli->query("DELETE FROM Undergraduate WHERE StudentID = $uid");
            }

            // 2. With that gone, the type can change.
            $q = $mysqli->prepare("
                UPDATE Student
                SET StudentType=?
                WHERE StudentID=?
            ");
            $q->bind_param("si", $_POST['StudentType'], $uid);
            $q->execute();
            $q->close();

            // 3. And the row for the new type can go in.
            if ($_POST['StudentType'] === "Undergraduate") {

                $q = $mysqli->prepare("
                    REPLACE INTO Undergraduate(StudentID, DeptID, UGStudentType)
                    VALUES (?, (SELECT DeptID FROM Major WHERE MajorID=?), ?)
                ");
                $q->bind_param("iis", $uid, $_POST['MajorID'], $_POST['UGStudentType']);
                $q->execute();
                $q->close();

            } else {

                $q = $mysqli->prepare("
                    REPLACE INTO Graduate(StudentID, DeptID, Year, GradStudentType, ProgramID)
                    VALUES (?, (SELECT DeptID FROM Program WHERE ProgramID=?), 1, ?, ?)
                ");
                $q->bind_param("issi", $uid, $_POST['ProgramID'], $_POST['GradStudentType'], $_POST['ProgramID']);
                $q->execute();
                $q->close();
            }

            // 4. Declarations last. trg_StudentMajor_after_* and
            //    trg_StudentMinor_after_* set Student.MajorID and MinorID
            //    from these, so nothing here writes those columns.
            $mysqli->query("DELETE FROM StudentMajor WHERE StudentID = $uid");
            if (!empty($_POST['MajorID'])) {
                $q = $mysqli->prepare("INSERT INTO StudentMajor(StudentID, MajorID, DateOfDeclaration) VALUES (?, ?, CURRENT_DATE)");
                $q->bind_param("ii", $uid, $_POST['MajorID']);
                $q->execute();
                $q->close();
            }

            $mysqli->query("DELETE FROM StudentMinor WHERE StudentID = $uid");
            if (!empty($_POST['MinorID'])) {
                $q = $mysqli->prepare("INSERT INTO StudentMinor(StudentID, MinorID, DateOfDeclaration) VALUES (?, ?, CURRENT_DATE)");
                $q->bind_param("ii", $uid, $_POST['MinorID']);
                $q->execute();
                $q->close();
            }
        }

        /* ----------------------
           FACULTY UPDATE
        ----------------------- */
        if ($role === 'Faculty') {

            // Update Faculty table
            $q = $mysqli->prepare("
                UPDATE Faculty
                SET OfficeID=?, Specialty=?, Ranking=?, FacultyType=?
                WHERE FacultyID=?
            ");
            $q->bind_param(
                "ssssi",
                $_POST['OfficeID'],
                $_POST['Specialty'],
                $_POST['Ranking'],
                $_POST['FacultyType'],
                $uid
            );
            $q->execute();
            $q->close();

            // Reset multi-departments
            $mysqli->query("DELETE FROM Faculty_Dept WHERE FacultyID = $uid");

            if (!empty($_POST['Departments'])) {
                foreach ($_POST['Departments'] as $dept) {
                    $ins = $mysqli->prepare("
                        INSERT INTO Faculty_Dept(FacultyID, DeptID, DOA)
                        VALUES (?, ?, CURRENT_DATE)
                    ");
                    $ins->bind_param("ii", $uid, $dept);
                    $ins->execute();
                    $ins->close();
                }
            }
        }

        /* ----------------------
           ADMIN UPDATE
        ----------------------- */
        if ($role === 'Admin') {
            $q = $mysqli->prepare("UPDATE Admin SET SecurityType=? WHERE AdminID=?");
            $q->bind_param("si", $_POST['SecurityType'], $uid);
            $q->execute();
            $q->close();
        }

        /* ----------------------
           STAT STAFF UPDATE
        ----------------------- */
        if ($role === 'StatStaff') {
            $q = $mysqli->prepare("
                UPDATE StatStaff
                SET StaffName=(SELECT CONCAT(FirstName,' ',LastName) FROM Users WHERE UserID=?)
                WHERE StatStaffID=?
            ");
            $q->bind_param("ii", $uid, $uid);
            $q->execute();
            $q->close();
        }

        $mysqli->commit();
        $_SESSION['update_success'] = true;
        $successMsg = "User updated successfully!";
    
    } catch (Exception $e) {
        $mysqli->rollback();
        die("Error updating user: " . $e->getMessage());
    }
}

$userId = $_SESSION['user_id'];

$usersql = "SELECT UserID, FirstName, LastName, Email, UserType, Status, DOB
        FROM Users WHERE UserID = ? LIMIT 1";
$userstmt = $mysqli->prepare($usersql);
$userstmt->bind_param("i", $userId);
$userstmt->execute();
$userres = $userstmt->get_result();
$user = $userres->fetch_assoc();
$userstmt->close();


?>

<!doctype html>
<html lang="en">
<?php $nu_title = 'Update Users'; require __DIR__ . '/partials/head.php'; ?>

<body>

<?php $nu_page = 'Update Users'; $nu_crumb = ['createDirectory.php', '← Back to Directory']; $nu_bell = false; require __DIR__ . '/partials/header.php'; ?>

<div id="toast" class="toast hidden">User updated successfully!</div>

<?php if (!empty($successMsg)): ?>
    <script>
        showToast("✅ User updated successfully!");
    </script>
<?php endif; ?>

<main id="main" tabindex="-1" class="page">

<!-- SEARCH USER CARD -->
<section class="hero card">
    <div class="card-head">
        <h2>Search for User to Update</h2>
    </div>

    <form method="POST" style="margin-top: 10px;">
        <div class="field-block">
            <label for="userid">UserID</label>
            <input id="userid" type="text" name="searchID" required placeholder="Enter UserID...">
        </div>

        <button type="submit" name="searchUser" class="btn">Search</button>
    </form>
</section>


<!-- IF USER LOADED, DISPLAY FORM -->
<?php if (!empty($loadedUser)) : ?>

<section class="hero card" style="margin-top: 20px;">
    <h2>Update User: <?php echo htmlspecialchars($loadedUser['FirstName'] . " " . $loadedUser['LastName']); ?></h2>

    <form method="POST">

    <input type="hidden" name="UserID" value="<?php echo $loadedUser['UserID']; ?>">
    <input type="hidden" name="UserType" value="<?php echo $loadedUser['UserType']; ?>">

    <!-- USERS TABLE FIELDS -->
    <div class="section-card">
        <h3>Basic Information</h3>

        <div class="field-block">
            <label for="userid-read-only">UserID (Read Only)</label>
            <input id="userid-read-only" type="text" value="<?php echo $loadedUser['UserID']; ?>" readonly>
        </div>

        <div class="field-block">
            <label for="email-read-only">Email (Read Only)</label>
            <input id="email-read-only" type="text" value="<?php echo $loadedUser['Email']; ?>" readonly>
        </div>

        <div class="field-block">
            <label for="first-name">First Name</label>
            <input id="first-name" type="text" name="FirstName" value="<?php echo $loadedUser['FirstName']; ?>">
        </div>

        <div class="field-block">
            <label for="middle-name">Middle Name</label>
            <input id="middle-name" type="text" name="MiddleName" value="<?php echo $loadedUser['MiddleName']; ?>">
        </div>

        <div class="field-block">
            <label for="last-name">Last Name</label>
            <input id="last-name" type="text" name="LastName" value="<?php echo $loadedUser['LastName']; ?>">
        </div>

        <div class="field-block">
            <label for="house-number">House Number</label>
            <input id="house-number" type="text" name="HouseNumber" value="<?php echo $loadedUser['HouseNumber']; ?>">
        </div>

        <div class="field-block">
            <label for="street">Street</label>
            <input id="street" type="text" name="Street" value="<?php echo $loadedUser['Street']; ?>">
        </div>

        <div class="field-block">
            <label for="city">City</label>
            <input id="city" type="text" name="City" value="<?php echo $loadedUser['City']; ?>">
        </div>

        <div class="field-block">
            <label for="state">State</label>
            <input id="state" type="text" name="State" value="<?php echo $loadedUser['State']; ?>">
        </div>

        <div class="field-block">
            <label for="zip">ZIP</label>
            <input id="zip" type="text" name="ZIP" value="<?php echo $loadedUser['ZIP']; ?>">
        </div>

        <div class="field-block">
            <label for="phone-number">Phone Number</label>
            <input id="phone-number" type="text" name="PhoneNumber" value="<?php echo $loadedUser['PhoneNumber']; ?>">
        </div>

        <div class="field-block">
            <label for="date-of-birth">Date of Birth</label>
            <input id="date-of-birth" type="date" name="DOB" value="<?php echo $loadedUser['DOB']; ?>">
        </div>

        <div class="field-block">
          <label for="status">Status</label>
             <select id="status" name="Status">
                <option value="ACTIVE" <?php if ($loadedUser['Status'] === 'ACTIVE') echo 'selected'; ?>>ACTIVE</option>
                <option value="INACTIVE" <?php if ($loadedUser['Status'] === 'INACTIVE') echo 'selected'; ?>>INACTIVE</option>
            </select>
        </div>

        <div class="field-block">
            <label for="gender">Gender</label>
            <select id="gender" name="Gender">
                <option value="M" <?php if ($loadedUser['Gender'] === 'M') echo 'selected'; ?>>Male</option>
                <option value="F" <?php if ($loadedUser['Gender'] === 'F') echo 'selected'; ?>>Female</option>
            </select>
        </div>
    </div>


<!-- STUDENT SECTION -->
<?php if ($loadedUser['UserType'] === 'Student') : ?>
    <div class="section-card" id="studentSection">
        <h3>Student Information</h3>

        <div class="field-block">
            <label for="StudentType">Student Type</label>
            <select name="StudentType" id="StudentType">
                <option value="Undergraduate" <?php if ($studentData['StudentType'] === "Undergraduate") echo "selected"; ?>>Undergraduate</option>
                <option value="Graduate" <?php if ($studentData['StudentType'] === "Graduate") echo "selected"; ?>>Graduate</option>
            </select>
        </div>

        <div class="field-block">
            <label for="MajorID">Major</label>
            <select name="MajorID" id="MajorID">
                <?php foreach (loadMajors($mysqli) as $m): ?>
                    <option value="<?php echo $m['MajorID']; ?>"
                        <?php if ($studentData['MajorID'] == $m['MajorID']) echo 'selected'; ?>>
                        <?php echo $m['MajorName']; ?>
                    </option>
                <?php endforeach; ?>
            </select>
        </div>

        <div class="field-block" id="MinorBlock">
            <label for="minor">Minor</label>
            <select id="minor" name="MinorID">
                <option value="">None</option>
                <?php foreach (loadMinors($mysqli) as $n): ?>
                    <option value="<?php echo $n['MinorID']; ?>"
                        <?php if ($studentData['MinorID'] == $n['MinorID']) echo 'selected'; ?>>
                        <?php echo $n['MinorName']; ?>
                    </option>
                <?php endforeach; ?>
            </select>
        </div>

        <!-- Undergrad sub-options -->
        <?php if ($studentData['StudentType'] === 'Undergraduate') : ?>
        <div class="field-block" id="UGTypeBlock">
            <label for="undergrad-type">Undergrad Type</label>
            <select id="undergrad-type" name="UGStudentType">
                <option value="FullTimeUG" <?php if ($studentData['UG']['UGStudentType'] === 'FullTimeUG') echo 'selected'; ?>>Full Time UG</option>
                <option value="PartTimeUG" <?php if ($studentData['UG']['UGStudentType'] === 'PartTimeUG') echo 'selected'; ?>>Part Time UG</option>
            </select>
        </div>
        <?php endif; ?>

        <!-- Graduate sub-options -->
        <?php if ($studentData['StudentType'] === 'Graduate') : ?>
        <div class="field-block" id="GradTypeBlock">
            <label for="grad-enrollment-type">Grad Enrollment Type</label>
            <select id="grad-enrollment-type" name="GradStudentType">
                <option value="FullTimeGrad" <?php if ($studentData['GR']['GradStudentType'] === 'FullTimeGrad') echo 'selected'; ?>>Full Time Grad</option>
                <option value="PartTimeGrad" <?php if ($studentData['GR']['GradStudentType'] === 'PartTimeGrad') echo 'selected'; ?>>Part Time Grad</option>
            </select>
        </div>

        <div class="field-block" id="ProgramBlock">
            <label for="graduate-program">Graduate Program</label>
            <select id="graduate-program" name="ProgramID">
                <?php foreach (loadPrograms($mysqli) as $p): ?>
                    <option value="<?php echo $p['ProgramID']; ?>"
                        <?php if ($studentData['GR']['ProgramID'] == $p['ProgramID']) echo 'selected'; ?>>
                        <?php echo $p['ProgramName']; ?>
                    </option>
                <?php endforeach; ?>
            </select>
        </div>
        <?php endif; ?>

    </div>
<?php endif; ?>


<!-- FACULTY SECTION -->
<?php if ($loadedUser['UserType'] === 'Faculty'): ?>
    <div class="section-card" id="facultySection">
        <h3>Faculty Information</h3>

        <div class="field-block">
            <label for="faculty-type">Faculty Type</label>
            <select id="faculty-type" name="FacultyType">
                <option value="FullTimeFaculty" <?php if ($facultyData['FacultyType'] === 'FullTimeFaculty') echo 'selected'; ?>>Full Time Faculty</option>
                <option value="PartTimeFaculty" <?php if ($facultyData['FacultyType'] === 'PartTimeFaculty') echo 'selected'; ?>>Part Time Faculty</option>
            </select>
        </div>

        <div class="field-block">
            <label for="office">Office</label>
            <select id="office" name="OfficeID">
                <?php foreach (loadOffices($mysqli) as $o): ?>
                    <option value="<?php echo $o['RoomID']; ?>"
                        <?php if ($facultyData['OfficeID'] == $o['RoomID']) echo 'selected'; ?>>
                        <?php echo $o['RoomID']; ?>
                    </option>
                <?php endforeach; ?>
            </select>
        </div>

        <div class="field-block">
            <label for="ranking">Ranking</label>
            <select id="ranking" name="Ranking">
                <option value="Dr." <?php if ($facultyData['Ranking'] === "Dr.") echo 'selected'; ?>>Dr.</option>
                <option value="Asst Prof" <?php if ($facultyData['Ranking'] === "Asst Prof") echo 'selected'; ?>>Asst Prof</option>
                <option value="Assoc Prof" <?php if ($facultyData['Ranking'] === "Assoc Prof") echo 'selected'; ?>>Assoc Prof</option>
                <option value="Professor" <?php if ($facultyData['Ranking'] === "Professor") echo 'selected'; ?>>Professor</option>
            </select>
        </div>

        <div class="field-block">
            <label for="specialty">Specialty</label>
            <input id="specialty" type="text" name="Specialty" value="<?php echo $facultyData['Specialty']; ?>">
        </div>

        <div class="field-block">
            <label for="departments-multi-select">Departments (Multi-Select)</label>
            <select id="departments-multi-select" name="Departments[]" class="multiselect" multiple>
                <?php foreach (loadDepartments($mysqli) as $d): ?>
                <option value="<?php echo $d['DeptID']; ?>"
                    <?php if (in_array($d['DeptID'], $facultyDepartments)) echo "selected"; ?>>
                    <?php echo $d['DeptName']; ?>
                </option>
                <?php endforeach; ?>
            </select>
        </div>

    </div>
<?php endif; ?>


<!-- ADMIN SECTION -->
<?php if ($loadedUser['UserType'] === 'Admin'): ?>
    <div class="section-card" id="adminSection">
        <h3>Admin Options</h3>

        <div class="field-block">
            <label for="security-type">Security Type</label>
            <select id="security-type" name="SecurityType">
                <option value="VIEW" <?php if ($adminData['SecurityType'] === 'VIEW') echo 'selected'; ?>>View Admin</option>
                <option value="UPDATE" <?php if ($adminData['SecurityType'] === 'UPDATE') echo 'selected'; ?>>Update Admin</option>
            </select>
        </div>
    </div>
<?php endif; ?>


<!-- STAT STAFF SECTION -->
<?php if ($loadedUser['UserType'] === 'StatStaff'): ?>
    <div class="section-card" id="statSection">
        <h3>Statistical Staff</h3>
        <p>Name is generated automatically from Users table on update.</p>
    </div>
<?php endif; ?>


<!-- SUBMIT BUTTON -->
<div style="margin-top: 20px;">
    <button type="submit" name="updateUser">Save Changes</button>
</div>

</form>

</section>

<?php endif; ?>


</main>

<?php require __DIR__ . '/partials/footer.php'; ?>

<script>
lucide.createIcons();
document.getElementById('year').textContent = new Date().getFullYear();
</script>

<script>
/* ============================================================================
   THEME TOGGLE
============================================================================ */
/* ============================================================================
   STUDENT DYNAMIC FORM CONTROL
   Handles:
   - Switching between Undergraduate and Graduate
   - Showing UGStudentType
   - Showing GradStudentType
   - Showing Grad Program
   - Hiding Minor for Grad
============================================================================ */
document.addEventListener("DOMContentLoaded", () => {

    const studentType = document.getElementById("StudentType");
    if (studentType) {
        studentType.addEventListener("change", updateStudentFormDisplay);
        updateStudentFormDisplay(); // run once on load
    }
});

function updateStudentFormDisplay() {

    const type = document.getElementById("StudentType")?.value;

    const minorBlock = document.getElementById("MinorBlock");
    const UGTypeBlock = document.getElementById("UGTypeBlock");
    const GradTypeBlock = document.getElementById("GradTypeBlock");
    const ProgramBlock = document.getElementById("ProgramBlock");

    // Hide all by default
    if (UGTypeBlock) UGTypeBlock.style.display = "none";
    if (GradTypeBlock) GradTypeBlock.style.display = "none";
    if (ProgramBlock) ProgramBlock.style.display = "none";

    // Show relevant fields
    if (type === "Undergraduate") {
        if (minorBlock) minorBlock.style.display = "block";
        if (UGTypeBlock) UGTypeBlock.style.display = "block";
        if (GradTypeBlock) GradTypeBlock.style.display = "none";
        if (ProgramBlock) ProgramBlock.style.display = "none";
    }

    if (type === "Graduate") {
        if (minorBlock) minorBlock.style.display = "none"; // Grad students do NOT have minors
        if (UGTypeBlock) UGTypeBlock.style.display = "none";
        if (GradTypeBlock) GradTypeBlock.style.display = "block";
        if (ProgramBlock) ProgramBlock.style.display = "block";
    }
}

lucide.createIcons();

function showToast(message) {
    const toast = document.getElementById("toast");
    toast.textContent = message;
    toast.classList.remove("hidden");

    // Trigger animation
    setTimeout(() => {
        toast.classList.add("show");
    }, 100);

    // Hide after 3 seconds
    setTimeout(() => {
        toast.classList.remove("show");
        setTimeout(() => toast.classList.add("hidden"), 300);
    }, 3000);
}

// Show success toast if update was successful
<?php if (!empty($_SESSION['update_success'])): ?>
    showToast("✅ User updated successfully!");
    <?php unset($_SESSION['update_success']); ?>
<?php endif; ?>
</script>
</body>
</html>