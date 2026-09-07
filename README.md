# Northport University Systems Project

A web-based university management system built with PHP, HTML, CSS, JavaScript, and MySQL/MariaDB.

## Test accounts

### Student

email: elizabeth.s.smith@nu.edu  
password: hashed_pw  
  
### Admin

email: donna.a.jones@nu.edu  
password: hashed_pw  
  
### Faculty  

email: joshua.t.taylor@nu.edu  
password: hashed_pw  
  


TO DOWNLOAD AND EXPLORE THE WEBSITE LOCALLY FOLLOW THE STEPS BELOW:

## Prerequisites

Download and install **XAMPP** before getting started:
- [https://www.apachefriends.org/download.html](https://www.apachefriends.org/download.html)

---

## Setup Instructions

### 1. Clone the Repository

Open a terminal, navigate to your XAMPP `htdocs` folder, and clone the project:

**Mac:**
```bash
cd /Applications/XAMPP/htdocs
git clone https://github.com/mcovelli/UniversityPortal
```

**Windows:**
```bash
cd C:/xampp/htdocs
git clone https://github.com/mcovelli/UniversityPortal
```

---

### 2. Start XAMPP Services

- **Mac:** Open XAMPP and click **Manager-osx**, then start **Apache Web Server** and **MySQL Database**
- **Windows:** Open the XAMPP Control Panel and click **Start** next to **Apache** and **MySQL**

---

### 3. Set Up the Database

1. Open your browser and go to `http://localhost/phpmyadmin`
2. Click **New** in the left sidebar to create a new database
3. Name it `University` and click **Create**
4. Select the `University` database, click the **Import** tab
5. Click **Choose File**, select the `University.sql` file, and click **Go**

---

### 4. Configure the Database Connection

1. Inside the project folder, find `config.example.php`
2. Make a copy of it and rename the copy to `config.php`
3. Open `config.php` and update the database credentials to match your local setup:

```php
$DB_HOST = '127.0.0.1';
$DB_PORT = 3306;
$DB_USER = 'root';       // or 'phpuser' if you have it set up
$DB_PASS = '';           // XAMPP root has no password by default
$DB_NAME = 'University';
```

---

### 5. Access the Website

Open your browser and go to:

```
http://localhost/UniversityPortal/login.html
```

---

## Alternative Setup: PHP Built-in Server (No XAMPP)

Don't want to install XAMPP? If you already have PHP and a local MySQL/MariaDB server (e.g. via Homebrew on Mac), you can run the site with PHP's built-in development server instead.

**Prerequisites:** PHP 8+ with the `mysqli` extension, and a running local MySQL/MariaDB server.

```bash
# Mac (Homebrew) example — skip if you already have these installed
brew install php mysql
brew services start mysql
```

### 1. Clone the Repository

The project doesn't need to live inside a web server's document root — clone it anywhere:

```bash
git clone https://github.com/mcovelli/UniversityPortal
```

### 2. Set Up the Database

Import the database with the `mysql` CLI instead of phpMyAdmin:

```bash
mysql -u root -p -e "CREATE DATABASE University"
mysql -u root -p University < UniversityPortal/University.sql
```

### 3. Configure the Database Connection

1. Inside the project folder, copy `config.example.php` to `config.php`
2. Update the credentials for your local setup:

```php
$DB_USER = getenv('DB_USER') ?: 'root';
$DB_PASS = getenv('DB_PASS') ?: '';   // your local MySQL root password, if any
```

Leave `PROJECT_ROOT` set to `/UniversityPortal` — the next step relies on it matching the URL path.

### 4. Start the PHP Built-in Server

Run the server from the **parent directory** of the cloned `UniversityPortal` folder (not from inside it), so `/UniversityPortal/...` URLs resolve the same way they would under XAMPP's `htdocs`:

```bash
cd /path/to/parent-folder-containing-UniversityPortal
php -S localhost:8000
```

### 5. Access the Website

```
http://localhost:8000/UniversityPortal/login.html
```

Press `Ctrl+C` in that terminal to stop the server. Re-run the same `php -S localhost:8000` command any time you want to start it again — no need to reinstall or reconfigure anything.

---

## Notes

- `config.php` is listed in `.gitignore` and will not be pushed to GitHub — keep your credentials safe
- If you're using the `phpuser` account instead of `root`, make sure it has the correct permissions on the `University` database
- This project was developed and tested on **MariaDB 10.4** — if you encounter collation errors on import, open `University.sql` in a text editor and replace all instances of `utf8mb4_0900_ai_ci` with `utf8mb4_general_ci`

