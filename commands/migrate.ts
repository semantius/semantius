/**
 * Migrate command implementation
 * Processes app names and checks for folder existence
 */

import { Client } from "@postgres";

export async function migrateCommand(apps: string, databaseUrl: string, verbose: boolean = false): Promise<void> {
  if (verbose) {
    console.info("Starting migrate command...");
  }
  
  try {
    // If no apps provided or empty, default to just "_dd"
    const appsToProcess = (!apps || apps.trim() === "") ? "_dd" : apps;
    
    // Add _dd prefix to the entire string if it doesn't start with "_dd," and it's not just "_dd"
    const processedAppsString = (appsToProcess === "_dd" || appsToProcess.startsWith("_dd,")) ? appsToProcess : `_dd,${appsToProcess}`;
    if (verbose) {
      console.info(`Processing apps parameter: ${appsToProcess}`);
      console.info(`Processed parameter: ${processedAppsString}`);
    }
    
    // Split the comma-separated string and trim whitespace
    const appList = processedAppsString.split(",").map(app => app.trim()).filter(app => app.length > 0);
    
    if (appList.length === 0) {
      console.error("No valid app names found");
      console.log("Provide comma-separated app names: app1,app2,app3");
      Deno.exit(1);
    }

    if (verbose) {
      console.info(`Found ${appList.length} app(s) to process`);
    }
    
    // Process each app name
    const processedApps: string[] = [];
    const existingApps: string[] = [];
    const missingApps: string[] = [];

    for (const app of appList) {
      // Use app as-is since we already processed the entire string
      const processedApp = app;
      processedApps.push(processedApp);
      
      console.log(`Checking for app: ${processedApp}`);
      
      // Check if folder exists in apps directory
      const appPath = `./apps/${processedApp}`;
      try {
        const stat = await Deno.stat(appPath);
        if (stat.isDirectory) {
          // Call migrateApp before logging success
          await migrateApp(processedApp, databaseUrl, processedApp, verbose);
          console.log(`Found: ${processedApp}`);
          existingApps.push(processedApp);
        } else {
          console.log(`Path exists but is not a directory: ${processedApp}`);
          missingApps.push(processedApp);
        }
      } catch (error) {
        if (error instanceof Deno.errors.NotFound) {
          console.log(`Not found: ${processedApp}`);
          missingApps.push(processedApp);
        } else {
          console.error(`Error checking ${processedApp}:`, error instanceof Error ? error.message : String(error));
          missingApps.push(processedApp);
        }
      }
    }

    // Summary
    if (verbose) {
      console.info("\nMigration Summary:");
      console.info(`Total apps processed: ${processedApps.length}`);
      console.info(`Existing apps found: ${existingApps.length}`);
      console.info(`Missing apps: ${missingApps.length}`);

      if (existingApps.length > 0) {
        console.info(`\nFound apps: ${existingApps.join(", ")}`);
      }

      if (missingApps.length > 0) {
        console.info(`\nMissing apps: ${missingApps.join(", ")}`);
        console.info("Make sure the app folders exist in the apps/ directory");
      }

      if (missingApps.length === 0) {
        console.info("\nAll specified apps found and ready for migration!");
      }

      console.info("Migrate command completed!");
    }
    
  } catch (error) {
    console.error("Migrate command failed:", error instanceof Error ? error.message : String(error));
    Deno.exit(1);
  }
}

async function ensure_versions(client: Client, verbose: boolean = false): Promise<void> {
  // Check if _versions table exists
  const checkTableQuery = `
    SELECT EXISTS (
      SELECT FROM information_schema.tables 
      WHERE table_schema = 'public' 
      AND table_name = '_versions'
    );
  `;
  
  const tableExists = await client.queryObject(checkTableQuery);
  const exists = (tableExists.rows[0] as { exists: boolean }).exists;
  
  if (!exists) {   
    
    // Create the _versions table
    const createTableQuery = `
      CREATE TABLE _versions (
        name TEXT PRIMARY KEY,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL
      );
      
      CREATE UNIQUE INDEX idx_versions_name ON _versions(name);
    `;
    
    await client.queryObject(createTableQuery);
    if (verbose) {
      console.info(`Created _versions table`);
    }
  } 
}

async function migrateApp(appName: string, databaseUrl: string, folderName: string, verbose: boolean = false): Promise<void> {
  if (verbose) {
    console.info(`Connecting to database for app: ${appName}`);
  }
  
  const client = new Client(databaseUrl);
  
  try {
    // Connect to the database
    await client.connect();
    if (verbose) {
      console.info(`Database connection established for ${appName}`);
    }
    
    // Ensure _versions table exists
    await ensure_versions(client, verbose);
    
    // Execute migrations for this app
    await executeMigrations(appName, folderName, client, verbose);
    
  } catch (error) {
    if (error instanceof Error) {
      if (error.message.includes("authentication failed")) {
        throw new Error(`Authentication failed for ${appName}. Check your username and password in DATABASE_URL.`);
      } else if (error.message.includes("database") && error.message.includes("does not exist")) {
        throw new Error(`Database does not exist for ${appName}. Check the database name in DATABASE_URL.`);
      } else if (error.message.includes("Connection refused")) {
        throw new Error(`Connection refused for ${appName}. Database server may not be running or network issues.`);
      } else if (error.message.includes("SSL")) {
        throw new Error(`SSL connection error for ${appName}. Check SSL configuration in DATABASE_URL.`);
      } else {
        throw new Error(`Database operation failed for ${appName}: ${error.message}`);
      }
    } else {
      throw new Error(`Database operation failed for ${appName}: ${String(error)}`);
    }
  } finally {
    // Always close the connection
    try {
      await client.end();
      if (verbose) {
        console.info(`Database connection closed for ${appName}`);
      }
    } catch (_closeError) {
      console.warn(`Warning: Could not close database connection properly for ${appName}`);
    }
  }
}

async function getMigrationFiles(folderName: string, verbose: boolean = false): Promise<string[]> {
  const migrationPath = `./apps/${folderName}/migrations`;
  
  try {
    const migrationFiles: string[] = [];
    
    // Read all entries in the migrations directory
    for await (const dirEntry of Deno.readDir(migrationPath)) {
      if (dirEntry.isFile && dirEntry.name.endsWith('.sql')) {
        migrationFiles.push(dirEntry.name);
      }
    }
    
    // Sort files ascending by filename
    migrationFiles.sort();
    
    return migrationFiles;
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) {
      if (verbose) {
        console.info(`No migrations folder found at: ${migrationPath}`);
      }
      return [];
    } else {
      console.error(`Error reading migrations folder ${migrationPath}:`, error instanceof Error ? error.message : String(error));
      return [];
    }
  }
}

async function executeSqlFile(client: Client, folderName: string, fileName: string): Promise<void> {
  const filePath = `./apps/${folderName}/migrations/${fileName}`;
  
  // Start transaction
  await client.queryObject("BEGIN");
  
  try {
    // Read the SQL file contents
    const sqlContent = await Deno.readTextFile(filePath);
    
    if (!sqlContent.trim()) {
      throw new Error(`Migration file ${fileName} is empty or contains only whitespace`);
    }
    
    // Execute the SQL content
    await client.queryObject(sqlContent);
    
    // Insert fileName in _versions table after successful execution
    const insertVersionQuery = `
      INSERT INTO _versions (name) VALUES ($1)
    `;
    await client.queryObject(insertVersionQuery, [fileName]);
    
    // Commit transaction
    await client.queryObject("COMMIT");
    
  } catch (error) {
    // Rollback transaction on any error
    try {
      await client.queryObject("ROLLBACK");
    } catch (rollbackError) {
      console.error(`Warning: Failed to rollback transaction for ${fileName}:`, rollbackError instanceof Error ? rollbackError.message : String(rollbackError));
    }
    
    // Re-throw the original error with proper context
    if (error instanceof Deno.errors.NotFound) {
      throw new Error(`Migration file not found: ${filePath}`);
    } else if (error instanceof Error) {
      throw new Error(`Failed to execute migration ${fileName}: ${error.message}`);
    } else {
      throw new Error(`Failed to execute migration ${fileName}: ${String(error)}`);
    }
  }
}

async function executeMigrations(appName: string, folderName: string, client: Client, verbose: boolean = false): Promise<void> {
  if (verbose) {
    console.info(`Getting migration files for app: ${appName}`);
  }
  
  // Try to acquire advisory lock to prevent concurrent migrations
  if (verbose) {
    console.info(`Attempting to acquire migration lock for ${appName}...`);
  }
  const lockResult = await client.queryObject("SELECT pg_try_advisory_lock(hashtext('migrate'))");
  const lockAcquired = (lockResult.rows[0] as { pg_try_advisory_lock: boolean }).pg_try_advisory_lock;
  
  if (!lockAcquired) {
    throw new Error(`Failed to acquire migration lock for ${appName}. Another migration process may be running.`);
  }
  
  if (verbose) {
    console.info(`Migration lock acquired for ${appName}`);
  }
  
  try {
    // Get all migration files for this app
    const migrationFiles = await getMigrationFiles(folderName, verbose);
    
    if (migrationFiles.length === 0) {
      if (verbose) {
        console.info(`No migration files found for ${appName}`);
      }
      return;
    }
    
    if (verbose) {
      console.info(`Found ${migrationFiles.length} migration file(s) for ${appName}:`);
    }
    
    // Loop over the list and execute each migration file
    for (const migrationFile of migrationFiles) {
      if (verbose) {
        console.info(`  ${migrationFile}`);
      }
      
      // versionName is file name with extension
      const versionName = migrationFile;
      
      // Check if this version already exists in _versions table
      const checkVersionQuery = `
        SELECT EXISTS (
          SELECT 1 FROM _versions 
          WHERE name = $1
        );
      `;
      
      const versionResult = await client.queryObject(checkVersionQuery, [versionName]);
      const versionExists = (versionResult.rows[0] as { exists: boolean }).exists;
      
      if (versionExists) {
        if (verbose) {
          console.info(`  Skipping ${versionName} - already applied`);
        }
        continue;
      }
      
      if (verbose) {
        console.info(`  Executing migration: ${versionName}`);
      }
      
      // Execute the SQL file
      await executeSqlFile(client, folderName, versionName);
      
      if (verbose) {
        console.info(`  Migration ${versionName} completed and recorded`);
      }
    }
    
  } finally {
    // Always release the advisory lock
    try {
      await client.queryObject("SELECT pg_advisory_unlock(hashtext('migrate'))");
      if (verbose) {
        console.info(`Migration lock released for ${appName}`);
      }
    } catch (unlockError) {
      console.error(`Warning: Failed to release migration lock for ${appName}:`, unlockError instanceof Error ? unlockError.message : String(unlockError));
    }
  }
}