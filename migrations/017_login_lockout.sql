-- =====================================================================
-- 017_login_lockout.sql
-- Group F from the trigger review: the lockout as a property of the
-- database, not of one file.
-- =====================================================================
--
--   mysql -h 127.0.0.1 -u root University < 017_login_lockout.sql
--
-- ---------------------------------------------------------------------
-- WHY
-- ---------------------------------------------------------------------
-- login.php already does this correctly: three failed attempts sets
-- MustReset = 1, and it's the only file that writes LoginAttempts.
-- reset_password.php and CreateUsers.php are the only other writers,
-- and both are unlock/create paths that never push LoginAttempts past
-- the threshold. So this trigger has nothing to catch today -- it's
-- here because "the lockout is enforced" shouldn't depend on staying
-- true forever about which file writes Login. If a second write path
-- ever bumps LoginAttempts to 3 without also setting MustReset, this
-- is what makes that impossible instead of just unlikely.
-- ---------------------------------------------------------------------
DROP TRIGGER IF EXISTS `trg_Login_before_update_lockout`;
DELIMITER $$
CREATE TRIGGER `trg_Login_before_update_lockout`
BEFORE UPDATE ON `Login` FOR EACH ROW
BEGIN
  IF NEW.`LoginAttempts` >= 3 THEN
    SET NEW.`MustReset` = 1;
  END IF;
END$$
DELIMITER ;


-- ---------------------------------------------------------------------
-- After
-- ---------------------------------------------------------------------
SELECT COUNT(*) AS trigger_count_expect_39
  FROM information_schema.`TRIGGERS` WHERE `TRIGGER_SCHEMA` = DATABASE();
