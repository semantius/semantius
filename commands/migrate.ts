/**
 * Migrate command implementation
 * Processes app names and checks for folder existence
 */

import { Client } from "@postgres";

export async function migrateCommand(apps: string, databaseUrl: string, scriptMode: boolean = false): Promise<void> {
  console.info("Starting migrate command...");
  
  // If in script mode, generate SQL file instead of executing
  if (scriptMode) {
    await generateMigrationScript(apps);
    return;
  }
  
  const client = new Client(databaseUrl);
  
  try {
    // Connect to the database to acquire global lock
    await client.connect();
    
    // Try to acquire advisory lock to prevent concurrent migrations
    console.info("Attempting to acquire global migration lock...");
    const lockResult = await client.queryObject("SELECT pg_try_advisory_lock(hashtext('migrate'))");
    const lockAcquired = (lockResult.rows[0] as { pg_try_advisory_lock: boolean }).pg_try_advisory_lock;
    
    if (!lockAcquired) {
      throw new Error("Failed to acquire global migration lock. Another migration process may be running.");
    }
    
    console.info("Global migration lock acquired");

    try {
      // If no apps provided or empty, default to just "_core"
      const appsToProcess = (!apps || apps.trim() === "") ? "_core" : apps;
      
      // Add _core prefix to the entire string if it doesn't start with "_core," and it's not just "_core"
      const processedAppsString = (appsToProcess === "_core" || appsToProcess.startsWith("_core,")) ? appsToProcess : `_core,${appsToProcess}`;
      console.info(`Processing apps parameter: ${appsToProcess}`);
      console.info(`Processed parameter: ${processedAppsString}`);
      
      // Split the comma-separated string and trim whitespace
      const appList = processedAppsString.split(",").map(app => app.trim()).filter(app => app.length > 0);
      
      if (appList.length === 0) {
        console.error("No valid app names found");
        console.log("Provide comma-separated app names: app1,app2,app3");
        Deno.exit(1);
      }

      console.info(`Found ${appList.length} app(s) to process`);
      
      // Process each app name
      const processedApps: string[] = [];
      const existingApps: string[] = [];
      const missingApps: string[] = [];

      for (const app of appList) {
        // Use app as-is since we already processed the entire string
        const processedApp = app;
        processedApps.push(processedApp);
        
        console.log(`Migrating: ${processedApp}`);
        
        // Check if folder exists in apps directory
        const appPath = `./apps/${processedApp}`;
        try {
          const stat = await Deno.stat(appPath);
          if (stat.isDirectory) {
            // Call migrateApp - any errors here should stop the entire process
            await migrateApp(processedApp, databaseUrl, processedApp);
            console.info(`Migrated: ${processedApp}`);
            existingApps.push(processedApp);
          } else {
            console.log(`Path exists but is not a directory: ${processedApp}`);
            missingApps.push(processedApp);
          }
        } catch (error) {
          // Only catch directory check errors, not migration errors
          if (error instanceof Deno.errors.NotFound) {
            console.log(`Not found: ${processedApp}`);
            missingApps.push(processedApp);
          } else {
            // If it's not a NotFound error, it's likely a migration error - re-throw to stop processing
            throw error;
          }
        }
      }

      // Summary
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
      
    } finally {
      // Always release the advisory lock
      try {
        await client.queryObject("SELECT pg_advisory_unlock(hashtext('migrate'))");
        console.info("Global migration lock released");
      } catch (unlockError) {
        console.error("Warning: Failed to release global migration lock:", unlockError instanceof Error ? unlockError.message : String(unlockError));
      }
    }
    
  } catch (error) {
    console.error("Migrate command failed:", error instanceof Error ? error.message : String(error));
    Deno.exit(1);
  } finally {
    // Always close the connection
    try {
      await client.end();
    } catch (_closeError) {
      console.warn("Warning: Could not close database connection properly");
    }
  }
}

function getVersionsTableSql(): string {
  return `CREATE SCHEMA IF NOT EXISTS common;

CREATE TABLE IF NOT EXISTS common._migration_history (
  name TEXT PRIMARY KEY,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_migration_history_name ON common._migration_history(name);

ALTER TABLE common._migration_history ENABLE ROW LEVEL SECURITY;`;
}

async function ensure_versions(client: Client): Promise<void> {
  // Check if _migration_history table exists
  const checkTableQuery = `
    SELECT EXISTS (
      SELECT FROM information_schema.tables 
      WHERE table_schema = 'common' 
      AND table_name = '_migration_history'
    );
  `;
  
  const tableExists = await client.queryObject(checkTableQuery);
  const exists = (tableExists.rows[0] as { exists: boolean }).exists;
  
  if (!exists) {   
    
    // Create the _migration_history table with RLS enabled using shared SQL
    const createTableQuery = getVersionsTableSql();
    
    await client.queryObject(createTableQuery);
    console.info(`Created common._migration_history table`);
  } 
}

async function migrateApp(appName: string, databaseUrl: string, folderName: string): Promise<void> {
  console.info(`Connecting to database for app: ${appName}`);
  
  const client = new Client(databaseUrl);
  
  try {
    // Connect to the database
    await client.connect();
    console.info(`Database connection established for ${appName}`);
    
    // Ensure _migration_history table exists
    await ensure_versions(client);
    
    // Execute migrations for this app
    await executeMigrations(appName, folderName, client);   
    
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
      console.info(`Database connection closed for ${appName}`);
    } catch (_closeError) {
      console.warn(`Warning: Could not close database connection properly for ${appName}`);
    }
  }
}

async function getSqlFiles(folderName: string, subfolder: string): Promise<string[]> {
  const sqlPath = `./apps/${folderName}/${subfolder}`;
  
  try {
    const sqlFiles: string[] = [];
    
    // Read all entries in the directory
    for await (const dirEntry of Deno.readDir(sqlPath)) {
      if (dirEntry.isFile && dirEntry.name.endsWith('.sql')) {
        sqlFiles.push(dirEntry.name);
      }
    }
    
    // Sort files ascending by filename
    sqlFiles.sort();
    
    return sqlFiles;
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) {
      console.info(`No ${subfolder} folder found at: ${sqlPath}`);
      return [];
    } else {
      console.error(`Error reading ${subfolder} folder ${sqlPath}:`, error instanceof Error ? error.message : String(error));
      return [];
    }
  }
}

async function executeSQL(client: Client, sqlContent: string, fileName: string): Promise<void> {
  try {
    // Execute the SQL content
    await client.queryObject(sqlContent);
  } catch (sqlError) {
    // Capture and display detailed PostgreSQL error information
    console.error(`\n=== SQL Error in ${fileName} ===`);
    
    if (sqlError instanceof Error) {
      console.error(`Message: ${sqlError.message}`);
      
      // Check if this is a PostgresError with fields
      const postgresError = sqlError as Error & {
        fields?: {
          severity?: string;
          code?: string;
          message?: string;
          position?: string;
          detail?: string;
          hint?: string;
          where?: string;
          file?: string;
          line?: string;
          routine?: string;
        };
      };
      
      if (postgresError.fields) {
        const fields = postgresError.fields;
        if (fields.severity) console.error(`Severity: ${fields.severity}`);
        if (fields.code) console.error(`Code: ${fields.code}`);
        if (fields.detail) console.error(`Detail: ${fields.detail}`);
        if (fields.hint) console.error(`Hint: ${fields.hint}`);
        if (fields.where) console.error(`Where: ${fields.where}`);
        if (fields.position) console.error(`Position: ${fields.position}`);
        
        let errorLine = "";
        // Show the problematic SQL line if position is available
        if (fields.position) {
          const position = parseInt(fields.position) - 1; // PostgreSQL positions are 1-based
          const lines = sqlContent.split('\n');
          let charCount = 0;
          let lineNumber = 1;
          
          for (const line of lines) {
            if (position >= charCount && position < charCount + line.length) {
              errorLine = `LINE ${lineNumber}: ${line}`;
              console.error(errorLine);
              break;
            }
            charCount += line.length + 1; // +1 for newline
            lineNumber++;
          }
        }
        
        console.error(`=== End SQL Error ===\n`);
        
        // Include line information in the thrown error
        const errorMsg = errorLine 
          ? `SQL execution failed in ${fileName}: ${sqlError.message}\n${errorLine}`
          : `SQL execution failed in ${fileName}: ${sqlError.message}`;
        throw new Error(errorMsg);
      }
    }
    
    throw sqlError;
  }
}



async function executeSqlFile(client: Client, folderName: string, fileName: string, versionName: string): Promise<void> {
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
    await executeSQL(client, sqlContent, fileName);
    
    // Insert versionName in _migration_history table after successful execution
    const insertVersionQuery = `
      INSERT INTO common._migration_history (name) VALUES ($1)
    `;
    await client.queryObject(insertVersionQuery, [versionName]);
    
    // Notify PostgREST to reload schema after migration
    await client.queryObject("NOTIFY pgrst, 'reload schema'");
    
    // Commit transaction
    await client.queryObject("COMMIT");
    
  } catch (error) {
    // Rollback transaction on any error
    try {
      await client.queryObject("ROLLBACK");
    } catch (rollbackError) {
      console.error(`Warning: Failed to rollback transaction for ${fileName}:`, rollbackError instanceof Error ? rollbackError.message : String(rollbackError));
    }
    
    // Re-throw the original error - preserve detailed SQL error information
    if (error instanceof Deno.errors.NotFound) {
      throw new Error(`Migration file not found: ${filePath}`);
    }
    
    // Don't wrap SQL execution errors - they already have detailed info
    throw error;
  }
}



async function executeFunctionFile(client: Client, folderName: string, fileName: string): Promise<void> {
  const filePath = `./apps/${folderName}/functions/${fileName}`;
  
  // Start transaction
  await client.queryObject("BEGIN");
  
  try {
    // Read the SQL file contents
    const sqlContent = await Deno.readTextFile(filePath);
    
    if (!sqlContent.trim()) {
      throw new Error(`Function file ${fileName} is empty or contains only whitespace`);
    }
    
    // Execute the SQL content
    await executeSQL(client, sqlContent, fileName);
    
    // Commit transaction
    await client.queryObject("COMMIT");
    
  } catch (error) {
    // Rollback transaction on any error
    try {
      await client.queryObject("ROLLBACK");
    } catch (rollbackError) {
      console.error(`Warning: Failed to rollback transaction for ${fileName}:`, rollbackError instanceof Error ? rollbackError.message : String(rollbackError));
    }
    
    // Re-throw the original error - preserve detailed SQL error information
    if (error instanceof Deno.errors.NotFound) {
      throw new Error(`Function file not found: ${filePath}`);
    }
    
    // Don't wrap SQL execution errors - they already have detailed info
    throw error;
  }
}

async function executeMigrations(appName: string, folderName: string, client: Client): Promise<void> {
  console.info(`Getting migration files for app: ${appName}`);
  
  // Get all migration files for this app
  const migrationFiles = await getSqlFiles(folderName, "migrations");
  
  if (migrationFiles.length === 0) {
    console.info(`No migration files found for ${appName}`);
    return;
  }
  
  console.info(`Found ${migrationFiles.length} migration file(s) for ${appName}:`);
  
  // Loop over the list and execute each migration file
  for (const migrationFile of migrationFiles) {
    console.info(`  ${migrationFile}`);
    
    // versionName is file name WITHOUT .sql extension AND prefixed with appName + "."
    const versionName = `${appName}.${migrationFile.replace(/\.sql$/, '')}`;
    
    // Check if this version already exists in _migration_history table
    const checkVersionQuery = `
      SELECT EXISTS (
        SELECT 1 FROM common._migration_history 
        WHERE name = $1
      );
    `;
    
    const versionResult = await client.queryObject(checkVersionQuery, [versionName]);
    const versionExists = (versionResult.rows[0] as { exists: boolean }).exists;
    
    if (versionExists) {
      console.info(`  Skipping ${versionName} - already applied`);
      continue;
    }
    
    console.info(`  Executing migration: ${versionName}`);
    
    // Execute the SQL file
    await executeSqlFile(client, folderName, migrationFile, versionName);
    
    console.info(`  Migration ${versionName} completed and recorded`);
  }
}

async function generateMigrationScript(apps: string): Promise<void> {
  console.log("Generating migration script...");
  
  // If no apps provided or empty, default to just "_core"
  const appsToProcess = (!apps || apps.trim() === "") ? "_core" : apps;
  
  // Add _core prefix to the entire string if it doesn't start with "_core," and it's not just "_core"
  const processedAppsString = (appsToProcess === "_core" || appsToProcess.startsWith("_core,")) ? appsToProcess : `_core,${appsToProcess}`;
  console.info(`Processing apps parameter: ${appsToProcess}`);
  console.info(`Processed parameter: ${processedAppsString}`);
  
  // Split the comma-separated string and trim whitespace
  const appList = processedAppsString.split(",").map(app => app.trim()).filter(app => app.length > 0);
  
  if (appList.length === 0) {
    console.error("No valid app names found");
    console.log("Provide comma-separated app names: app1,app2,app3");
    Deno.exit(1);
  }

  console.info(`Found ${appList.length} app(s) to process`);
  
  let scriptContent = "-- Generated migration script\n\n";
  
  // First, create _migration_history table if it doesn't exist using shared SQL
  scriptContent += "-- Ensure _migration_history table exists\n";
  scriptContent += getVersionsTableSql();
  scriptContent += "\n\n";
  
  // Process each app
  for (const app of appList) {
    const processedApp = app;
    
    console.log(`Processing: ${processedApp}`);
    
    // Check if folder exists in apps directory
    const appPath = `./apps/${processedApp}`;
    try {
      const stat = await Deno.stat(appPath);
      if (!stat.isDirectory) {
        console.log(`Path exists but is not a directory: ${processedApp}`);
        continue;
      }
    } catch (error) {
      if (error instanceof Deno.errors.NotFound) {
        console.log(`Not found: ${processedApp}`);
        continue;
      }
      throw error;
    }
    
    // Get all migration files for this app
    const migrationFiles = await getSqlFiles(processedApp, "migrations");
    
    if (migrationFiles.length === 0) {
      console.info(`No migration files found for ${processedApp}`);
      continue;
    }
    
    console.info(`Found ${migrationFiles.length} migration file(s) for ${processedApp}`);
    
    // Process each migration file
    for (const migrationFile of migrationFiles) {
      const versionName = `${processedApp}.${migrationFile.replace(/\.sql$/, '')}`;
      const filePath = `./apps/${processedApp}/migrations/${migrationFile}`;
      
      console.info(`  Adding ${versionName}`);
      
      try {
        // Read the SQL file contents
        const sqlContent = await Deno.readTextFile(filePath);
        
        if (!sqlContent.trim()) {
          console.warn(`  Warning: Migration file ${migrationFile} is empty`);
          continue;
        }
        
        // Add a comment header
        scriptContent += `-- Migration: ${versionName}\n`;
        scriptContent += `BEGIN;\n\n`;
        
        // Add the SQL content
        scriptContent += sqlContent;
        
        // Ensure there's a newline before the version insert
        if (!sqlContent.endsWith('\n')) {
          scriptContent += '\n';
        }
        scriptContent += '\n';
        
        // Add version record
        scriptContent += `-- Record migration version\n`;
        scriptContent += `INSERT INTO common._migration_history (name) VALUES ('${versionName}');\n\n`;
        
        // Commit transaction
        scriptContent += `COMMIT;\n\n`;
        
      } catch (error) {
        if (error instanceof Deno.errors.NotFound) {
          console.error(`Migration file not found: ${filePath}`);
          continue;
        }
        throw error;
      }
    }
  }
  
  // Add NOTIFY at the end once
  scriptContent += "-- Notify PostgREST to reload schema\n";
  scriptContent += "NOTIFY pgrst, 'reload schema';\n";
  
  // Write to migrate.sql
  const outputPath = "./migrate.sql";
  await Deno.writeTextFile(outputPath, scriptContent);
  
  console.log(`\nMigration script generated: ${outputPath}`);
  console.log("Script generation completed!");
}