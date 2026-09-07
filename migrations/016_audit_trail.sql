-- =====================================================================
-- 016_audit_trail.sql
-- Group E from the trigger review: a real audit trail for the identity
-- table, grades, and holds.
-- =====================================================================
--
--   mysql -h 127.0.0.1 -u root University < 016_audit_trail.sql
--
-- Requires config.php's get_db() to set @nu_actor -- already shipped
-- alongside this migration. Without it every row below reads ChangedBy
-- as NULL rather than root, which is honest but useless; it needs the
-- PHP change to mean anything.
--
-- ---------------------------------------------------------------------
-- WHY
-- ---------------------------------------------------------------------
-- AuditLog has existed since before these migrations started -- get_
-- auditlogs.php reads it -- and nothing has ever written to it. A
-- MySQL trigger can't see who is logged into the application on its
-- own: every page connects as root, so CURRENT_USER() is always
-- root@localhost. @nu_actor is config.php telling the database what
-- PHP already knows.
--
-- Three tables get a trail:
--
--   Users            -- address, email, status, and role (UserType)
--                        changes, old value and new. Covers the update-
--                        address action and any edit made to a student
--                        by someone else.
--   StudentEnrollment -- every grade change, who and when, old grade
--                        and new. The single most consequential field
--                        in the schema, and today it changes without a
--                        trace.
--   StudentHold       -- placing and clearing a hold. 012 made a hold
--                        block registration, so it's consequential now
--                        and needs the same trail.
-- ---------------------------------------------------------------------


-- ---------------------------------------------------------------------
-- 1. Users -- address, email, status, role
-- ---------------------------------------------------------------------
DROP TRIGGER IF EXISTS `trg_Users_after_update_audit`;
DELIMITER $$
CREATE TRIGGER `trg_Users_after_update_audit`
AFTER UPDATE ON `Users` FOR EACH ROW
BEGIN
  DECLARE v_details TEXT DEFAULT '';

  IF NOT (OLD.`Email` <=> NEW.`Email`) THEN
    SET v_details = CONCAT(v_details, 'Email: ', COALESCE(OLD.`Email`, 'NULL'),
                            ' -> ', COALESCE(NEW.`Email`, 'NULL'), '; ');
  END IF;

  IF NOT (OLD.`Status` <=> NEW.`Status`) THEN
    SET v_details = CONCAT(v_details, 'Status: ', COALESCE(OLD.`Status`, 'NULL'),
                            ' -> ', COALESCE(NEW.`Status`, 'NULL'), '; ');
  END IF;

  IF NOT (OLD.`UserType` <=> NEW.`UserType`) THEN
    SET v_details = CONCAT(v_details, 'Role: ', COALESCE(OLD.`UserType`, 'NULL'),
                            ' -> ', COALESCE(NEW.`UserType`, 'NULL'), '; ');
  END IF;

  IF NOT (OLD.`HouseNumber` <=> NEW.`HouseNumber`) OR NOT (OLD.`Street` <=> NEW.`Street`)
     OR NOT (OLD.`City` <=> NEW.`City`) OR NOT (OLD.`State` <=> NEW.`State`)
     OR NOT (OLD.`ZIP` <=> NEW.`ZIP`) THEN
    SET v_details = CONCAT(v_details, 'Address: ',
      COALESCE(OLD.`HouseNumber`, ''), ' ', COALESCE(OLD.`Street`, ''), ', ',
      COALESCE(OLD.`City`, ''), ', ', COALESCE(OLD.`State`, ''), ' ', COALESCE(OLD.`ZIP`, ''),
      ' -> ',
      COALESCE(NEW.`HouseNumber`, ''), ' ', COALESCE(NEW.`Street`, ''), ', ',
      COALESCE(NEW.`City`, ''), ', ', COALESCE(NEW.`State`, ''), ' ', COALESCE(NEW.`ZIP`, ''),
      '; ');
  END IF;

  IF v_details <> '' THEN
    INSERT INTO `AuditLog` (`TableName`, `RecordID`, `Operation`, `ChangedBy`, `Details`)
    VALUES ('Users', NEW.`UserID`, 'UPDATE', @nu_actor, v_details);
  END IF;
END$$
DELIMITER ;


-- ---------------------------------------------------------------------
-- 2. StudentEnrollment -- every grade change
-- ---------------------------------------------------------------------
DROP TRIGGER IF EXISTS `trg_SE_after_update_gradeaudit`;
DELIMITER $$
CREATE TRIGGER `trg_SE_after_update_gradeaudit`
AFTER UPDATE ON `StudentEnrollment` FOR EACH ROW
BEGIN
  IF NOT (OLD.`Grade` <=> NEW.`Grade`) THEN
    INSERT INTO `AuditLog` (`TableName`, `RecordID`, `Operation`, `ChangedBy`, `Details`)
    VALUES ('StudentEnrollment', CONCAT(NEW.`StudentID`, '-', NEW.`SemesterID`, '-', NEW.`CRN`),
            'UPDATE', @nu_actor,
            CONCAT('Grade: ', COALESCE(OLD.`Grade`, 'NULL'), ' -> ', COALESCE(NEW.`Grade`, 'NULL')));
  END IF;
END$$
DELIMITER ;


-- ---------------------------------------------------------------------
-- 3. StudentHold -- placing and clearing
-- ---------------------------------------------------------------------
DROP TRIGGER IF EXISTS `trg_StudentHold_after_insert_audit`;
DELIMITER $$
CREATE TRIGGER `trg_StudentHold_after_insert_audit`
AFTER INSERT ON `StudentHold` FOR EACH ROW
BEGIN
  INSERT INTO `AuditLog` (`TableName`, `RecordID`, `Operation`, `ChangedBy`, `Details`)
  VALUES ('StudentHold', CONCAT(NEW.`StudentID`, '-', NEW.`HoldID`), 'INSERT', @nu_actor,
          CONCAT('Hold placed, HoldID=', NEW.`HoldID`, ', DateOfHold=', NEW.`DateOfHold`));
END$$
DELIMITER ;

DROP TRIGGER IF EXISTS `trg_StudentHold_after_delete_audit`;
DELIMITER $$
CREATE TRIGGER `trg_StudentHold_after_delete_audit`
AFTER DELETE ON `StudentHold` FOR EACH ROW
BEGIN
  INSERT INTO `AuditLog` (`TableName`, `RecordID`, `Operation`, `ChangedBy`, `Details`)
  VALUES ('StudentHold', CONCAT(OLD.`StudentID`, '-', OLD.`HoldID`), 'DELETE', @nu_actor,
          CONCAT('Hold cleared, HoldID=', OLD.`HoldID`, ', DateOfHold=', OLD.`DateOfHold`));
END$$
DELIMITER ;


-- ---------------------------------------------------------------------
-- 4. After
-- ---------------------------------------------------------------------
SELECT `TRIGGER_NAME`, `EVENT_OBJECT_TABLE`, `EVENT_MANIPULATION`
  FROM information_schema.`TRIGGERS`
 WHERE `TRIGGER_SCHEMA` = DATABASE() AND `TRIGGER_NAME` LIKE '%audit%'
 ORDER BY `EVENT_OBJECT_TABLE`;

SELECT COUNT(*) AS trigger_count_expect_38
  FROM information_schema.`TRIGGERS` WHERE `TRIGGER_SCHEMA` = DATABASE();
