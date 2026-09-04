/**
 * Dropall command implementation
 * Drops all objects in the public schema of the database
 * WARNING: This is a destructive operation that cannot be undone
 */

import { Client } from "@postgres";

export async function dropallCommand(databaseUrl: string, confirm: boolean = false, scriptMode: boolean = false): Promise<void> {
  // If in script mode, generate SQL file instead of executing
  if (scriptMode) {
    await generateDropallScript(databaseUrl);
    return;
  }
  
  console.warn("WARNING: DROP ALL COMMAND");
  console.warn("=".repeat(50));
  console.warn("This command will permanently delete ALL objects in the database:");
  console.warn("• All tables and their data");
  console.warn("• All views");
  console.warn("• All functions and procedures");
  console.warn("• All sequences");
  console.warn("• All types");
  console.warn("• All other database objects in the public schema");
  console.warn("• All user-owned schemas/namespaces (except 'public' and 'auth')");
  console.warn("");
  console.warn("THIS OPERATION CANNOT BE UNDONE!");
  console.warn("=".repeat(50));
  console.warn("");
  
  // Prompt for confirmation unless --confirm flag was provided
  if (!confirm) {
    const confirmation = prompt("Type 'Y' to confirm you want to delete all data: ");
    
    if (confirmation !== 'Y') {
      console.log("❌ Operation canceled - confirmation not received");
      return;
    }
  } else {
    console.log("⚠️ Confirmation skipped due to --confirm flag");
  }
  
  console.log("Starting dropall command...");
  
  const client = new Client(databaseUrl);
  
  try {
    // Connect to the database
    await client.connect();
    console.log("Database connection established");
    
    // Drop all objects in the public schema
    await dropAllObjects(client);
    
    console.log("Dropall command completed successfully!");
    console.log("All database objects have been removed");
    
  } catch (error) {
    if (error instanceof Error) {
      if (error.message.includes("authentication failed")) {
        console.error("Authentication failed. Check your username and password in DATABASE_URL.");
      } else if (error.message.includes("database") && error.message.includes("does not exist")) {
        console.error("Database does not exist. Check the database name in DATABASE_URL.");
      } else if (error.message.includes("Connection refused")) {
        console.error("Connection refused. Database server may not be running or network issues.");
      } else if (error.message.includes("SSL")) {
        console.error("SSL connection error. Check SSL configuration in DATABASE_URL.");
      } else {
        console.error("Dropall command failed:", error.message);
      }
    } else {
      console.error("Dropall command failed:", String(error));
    }
    Deno.exit(1);
  } finally {
    // Always close the connection
    try {
      await client.end();
      console.log("Database connection closed");
    } catch (_closeError) {
      console.warn("Warning: Could not close database connection properly");
    }
  }
}

async function generateDropallScript(databaseUrl: string): Promise<void> {
  console.log("Generating dropall script...");
  
  const client = new Client(databaseUrl);
  
  try {
    // Connect to the database
    await client.connect();
    console.info("Database connection established for script generation");
    
    let scriptContent = "-- Generated dropall script\n";
    scriptContent += "-- WARNING: This script will permanently delete ALL objects in the database\n";
    scriptContent += "-- Execute with caution!\n\n";
    
    // Generate SQL for dropping all objects in dependency order
    
    // 1. Drop all views
    scriptContent += await generateDropViewsSql(client);
    
    // 2. Drop all functions and procedures
    scriptContent += await generateDropFunctionsSql(client);
    
    // 3. Drop all tables
    scriptContent += await generateDropTablesSql(client);
    
    // 4. Drop all sequences
    scriptContent += await generateDropSequencesSql(client);
    
    // 5. Drop all custom types
    scriptContent += await generateDropTypesSql(client);
    
    // 6. Drop remaining objects
    scriptContent += await generateDropRemainingObjectsSql(client);
    
    // 7. Drop custom schemas
    scriptContent += await generateDropCustomSchemasSql(client);
    
    // Write to dropall.sql
    const outputPath = "./dropall.sql";
    await Deno.writeTextFile(outputPath, scriptContent);
    
    console.log(`\nDropall script generated: ${outputPath}`);
    console.log("Script generation completed!");
    
  } catch (error) {
    if (error instanceof Error) {
      console.error("Script generation failed:", error.message);
    } else {
      console.error("Script generation failed:", String(error));
    }
    Deno.exit(1);
  } finally {
    // Always close the connection
    try {
      await client.end();
      console.info("Database connection closed");
    } catch (_closeError) {
      console.warn("Warning: Could not close database connection properly");
    }
  }
}

async function generateDropViewsSql(client: Client): Promise<string> {
  const query = `
    SELECT schemaname, viewname 
    FROM pg_views 
    WHERE schemaname = 'public'
    ORDER BY viewname;
  `;
  
  const result = await client.queryObject(query);
  
  if (result.rows.length === 0) {
    console.info("No views found in public schema");
    return "-- No views found in public schema\n\n";
  }
  
  console.info(`Found ${result.rows.length} view(s) to drop`);
  
  let sql = "-- Drop all views\n";
  for (const row of result.rows) {
    const { viewname } = row as { schemaname: string; viewname: string };
    sql += `DROP VIEW IF EXISTS "${viewname}" CASCADE;\n`;
  }
  sql += "\n";
  
  return sql;
}

async function generateDropFunctionsSql(client: Client): Promise<string> {
  const query = `
    SELECT 
      p.proname as function_name,
      pg_get_function_identity_arguments(p.oid) as function_args
    FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
    ORDER BY p.proname;
  `;
  
  const result = await client.queryObject(query);
  
  if (result.rows.length === 0) {
    console.info("No functions found in public schema");
    return "-- No functions found in public schema\n\n";
  }
  
  console.info(`Found ${result.rows.length} function(s) to drop`);
  
  let sql = "-- Drop all functions and procedures\n";
  for (const row of result.rows) {
    const { function_name, function_args } = row as { function_name: string; function_args: string };
    sql += `DROP FUNCTION IF EXISTS "${function_name}"(${function_args}) CASCADE;\n`;
  }
  sql += "\n";
  
  return sql;
}

async function generateDropTablesSql(client: Client): Promise<string> {
  const query = `
    SELECT tablename 
    FROM pg_tables 
    WHERE schemaname = 'public'
    ORDER BY tablename;
  `;
  
  const result = await client.queryObject(query);
  
  if (result.rows.length === 0) {
    console.info("No tables found in public schema");
    return "-- No tables found in public schema\n\n";
  }
  
  console.info(`Found ${result.rows.length} table(s) to drop`);
  
  let sql = "-- Drop all tables\n";
  for (const row of result.rows) {
    const { tablename } = row as { tablename: string };
    sql += `DROP TABLE IF EXISTS "${tablename}" CASCADE;\n`;
  }
  sql += "\n";
  
  return sql;
}

async function generateDropSequencesSql(client: Client): Promise<string> {
  const query = `
    SELECT sequencename 
    FROM pg_sequences 
    WHERE schemaname = 'public'
    ORDER BY sequencename;
  `;
  
  const result = await client.queryObject(query);
  
  if (result.rows.length === 0) {
    console.info("No sequences found in public schema");
    return "-- No sequences found in public schema\n\n";
  }
  
  console.info(`Found ${result.rows.length} sequence(s) to drop`);
  
  let sql = "-- Drop all sequences\n";
  for (const row of result.rows) {
    const { sequencename } = row as { sequencename: string };
    sql += `DROP SEQUENCE IF EXISTS "${sequencename}" CASCADE;\n`;
  }
  sql += "\n";
  
  return sql;
}

async function generateDropTypesSql(client: Client): Promise<string> {
  const query = `
    SELECT t.typname 
    FROM pg_type t
    JOIN pg_namespace n ON t.typnamespace = n.oid
    WHERE n.nspname = 'public'
    AND t.typtype = 'c'
    ORDER BY t.typname;
  `;
  
  const result = await client.queryObject(query);
  
  if (result.rows.length === 0) {
    console.info("No custom types found in public schema");
    return "-- No custom types found in public schema\n\n";
  }
  
  console.info(`Found ${result.rows.length} custom type(s) to drop`);
  
  let sql = "-- Drop all custom types\n";
  for (const row of result.rows) {
    const { typname } = row as { typname: string };
    sql += `DROP TYPE IF EXISTS "${typname}" CASCADE;\n`;
  }
  sql += "\n";
  
  return sql;
}

async function generateDropRemainingObjectsSql(client: Client): Promise<string> {
  let sql = "";
  
  // Check for domains
  const domainQuery = `SELECT domain_name FROM information_schema.domains WHERE domain_schema = 'public'`;
  const domainResult = await client.queryObject(domainQuery);
  
  if (domainResult.rows.length > 0) {
    console.info(`Found ${domainResult.rows.length} domain(s) to drop`);
    sql += "-- Drop all domains\n";
    for (const row of domainResult.rows) {
      const { domain_name } = row as { domain_name: string };
      sql += `DROP DOMAIN IF EXISTS "${domain_name}" CASCADE;\n`;
    }
    sql += "\n";
  } else {
    console.info("No domains found in public schema");
    sql += "-- No domains found in public schema\n\n";
  }
  
  // Check for aggregates
  const aggregateQuery = `SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid WHERE n.nspname = 'public' AND p.prokind = 'a'`;
  const aggregateResult = await client.queryObject(aggregateQuery);
  
  if (aggregateResult.rows.length > 0) {
    console.info(`Found ${aggregateResult.rows.length} aggregate(s) to drop`);
    sql += "-- Drop all aggregates\n";
    for (const row of aggregateResult.rows) {
      const { proname } = row as { proname: string };
      sql += `DROP AGGREGATE IF EXISTS "${proname}" CASCADE;\n`;
    }
    sql += "\n";
  } else {
    console.info("No aggregates found in public schema");
    sql += "-- No aggregates found in public schema\n\n";
  }
  
  return sql;
}

async function generateDropCustomSchemasSql(client: Client): Promise<string> {
  const query = `
    SELECT n.nspname as schema_name, u.usename as owner
    FROM pg_namespace n
    JOIN pg_user u ON n.nspowner = u.usesysid    
    WHERE n.nspname NOT IN ('information_schema', 'pg_catalog', 'pg_toast', 'public', 'auth', 'extensions')    
    AND u.usename = current_user
    ORDER BY n.nspname;
  `;
  
  const result = await client.queryObject(query);
  
  if (result.rows.length === 0) {
    console.info("No user-owned schemas found to drop");
    return "-- No user-owned schemas found to drop\n";
  }
  
  console.info(`Found ${result.rows.length} user-owned schema(s) to drop`);
  
  let sql = "-- Drop all user-owned schemas\n";
  for (const row of result.rows) {
    const { schema_name } = row as { schema_name: string; owner: string };
    sql += `DROP SCHEMA IF EXISTS "${schema_name}" CASCADE;\n`;
  }
  sql += "\n";
  
  return sql;
}

async function dropAllObjects(client: Client): Promise<void> {
  console.log("Discovering database objects in public schema...");
  
  // Drop all objects in dependency order to avoid foreign key constraints
  
  // 1. Drop all views first (they depend on tables)
  await dropViews(client);
  
  // 2. Drop all functions and procedures
  await dropFunctions(client);
  
  // 3. Drop all tables (this will also drop foreign key constraints)
  await dropTables(client);
  
  // 4. Drop all sequences
  await dropSequences(client);
  
  // 5. Drop all custom types
  await dropTypes(client);
  
  // 6. Drop any remaining objects
  await dropRemainingObjects(client);
  
  // 7. Drop custom schemas/namespaces (except 'public' and 'auth')
  await dropCustomSchemas(client);
}

async function dropViews(client: Client): Promise<void> {
  const query = `
    SELECT schemaname, viewname 
    FROM pg_views 
    WHERE schemaname = 'public'
    ORDER BY viewname;
  `;
  
  const result = await client.queryObject(query);
  
  if (result.rows.length === 0) {
    console.log("No views found in public schema");
    return;
  }
  
  console.log(`Found ${result.rows.length} view(s) to drop:`);
  
  for (const row of result.rows) {
    const { viewname } = row as { schemaname: string; viewname: string };
    console.log(`  Dropping view: ${viewname}`);
    
    try {
      await client.queryObject(`DROP VIEW IF EXISTS "${viewname}" CASCADE`);
      console.log(`  Dropped view: ${viewname}`);
    } catch (error) {
      console.error(`  Failed to drop view ${viewname}:`, error instanceof Error ? error.message : String(error));
    }
  }
}

async function dropFunctions(client: Client): Promise<void> {
  const query = `
    SELECT 
      p.proname as function_name,
      pg_get_function_identity_arguments(p.oid) as function_args
    FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
    ORDER BY p.proname;
  `;
  
  const result = await client.queryObject(query);
  
  if (result.rows.length === 0) {
    console.log("No functions found in public schema");
    return;
  }
  
  console.log(`Found ${result.rows.length} function(s) to drop:`);
  
  for (const row of result.rows) {
    const { function_name, function_args } = row as { function_name: string; function_args: string };
    console.log(`  Dropping function: ${function_name}(${function_args})`);
    
    try {
      await client.queryObject(`DROP FUNCTION IF EXISTS "${function_name}"(${function_args}) CASCADE`);
      console.log(`  Dropped function: ${function_name}`);
    } catch (error) {
      console.error(`  Failed to drop function ${function_name}:`, error instanceof Error ? error.message : String(error));
    }
  }
}

async function dropTables(client: Client): Promise<void> {
  const query = `
    SELECT tablename 
    FROM pg_tables 
    WHERE schemaname = 'public'
    ORDER BY tablename;
  `;
  
  const result = await client.queryObject(query);
  
  if (result.rows.length === 0) {
    console.log("No tables found in public schema");
    return;
  }
  
  console.log(`Found ${result.rows.length} table(s) to drop:`);
  
  for (const row of result.rows) {
    const { tablename } = row as { tablename: string };
    console.log(`  Dropping table: ${tablename}`);
    
    try {
      await client.queryObject(`DROP TABLE IF EXISTS "${tablename}" CASCADE`);
      console.log(`  Dropped table: ${tablename}`);
    } catch (error) {
      console.error(`  Failed to drop table ${tablename}:`, error instanceof Error ? error.message : String(error));
    }
  }
}

async function dropSequences(client: Client): Promise<void> {
  const query = `
    SELECT sequencename 
    FROM pg_sequences 
    WHERE schemaname = 'public'
    ORDER BY sequencename;
  `;
  
  const result = await client.queryObject(query);
  
  if (result.rows.length === 0) {
    console.log("No sequences found in public schema");
    return;
  }
  
  console.log(`Found ${result.rows.length} sequence(s) to drop:`);
  
  for (const row of result.rows) {
    const { sequencename } = row as { sequencename: string };
    console.log(`  Dropping sequence: ${sequencename}`);
    
    try {
      await client.queryObject(`DROP SEQUENCE IF EXISTS "${sequencename}" CASCADE`);
      console.log(`  Dropped sequence: ${sequencename}`);
    } catch (error) {
      console.error(`  Failed to drop sequence ${sequencename}:`, error instanceof Error ? error.message : String(error));
    }
  }
}

async function dropTypes(client: Client): Promise<void> {
  const query = `
    SELECT t.typname 
    FROM pg_type t
    JOIN pg_namespace n ON t.typnamespace = n.oid
    WHERE n.nspname = 'public'
    AND t.typtype = 'c'  -- composite types
    ORDER BY t.typname;
  `;
  
  const result = await client.queryObject(query);
  
  if (result.rows.length === 0) {
    console.log("No custom types found in public schema");
    return;
  }
  
  console.log(`Found ${result.rows.length} custom type(s) to drop:`);
  
  for (const row of result.rows) {
    const { typname } = row as { typname: string };
    console.log(`  Dropping type: ${typname}`);
    
    try {
      await client.queryObject(`DROP TYPE IF EXISTS "${typname}" CASCADE`);
      console.log(`  Dropped type: ${typname}`);
    } catch (error) {
      console.error(`  Failed to drop type ${typname}:`, error instanceof Error ? error.message : String(error));
    }
  }
}

async function dropRemainingObjects(client: Client): Promise<void> {
  // Drop any remaining objects that might have been missed
  const queries = [
    // Drop all remaining domains
    `SELECT domain_name FROM information_schema.domains WHERE domain_schema = 'public'`,
    // Drop all remaining aggregates  
    `SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid WHERE n.nspname = 'public' AND p.prokind = 'a'`,
  ];
  
  // Check for domains
  try {
    const domainResult = await client.queryObject(queries[0]);
    if (domainResult.rows.length > 0) {
      console.log(`Found ${domainResult.rows.length} domain(s) to drop:`);
      for (const row of domainResult.rows) {
        const { domain_name } = row as { domain_name: string };
        console.log(`  Dropping domain: ${domain_name}`);
        try {
          await client.queryObject(`DROP DOMAIN IF EXISTS "${domain_name}" CASCADE`);
          console.log(`  Dropped domain: ${domain_name}`);
        } catch (error) {
          console.error(`  Failed to drop domain ${domain_name}:`, error instanceof Error ? error.message : String(error));
        }
      }
    } else {
      console.log("No domains found in public schema");
    }
  } catch (error) {
    console.error("Warning: Could not check for domains:", error instanceof Error ? error.message : String(error));
  }
  
  // Check for aggregates
  try {
    const aggregateResult = await client.queryObject(queries[1]);
    if (aggregateResult.rows.length > 0) {
      console.log(`Found ${aggregateResult.rows.length} aggregate(s) to drop:`);
      for (const row of aggregateResult.rows) {
        const { proname } = row as { proname: string };
        console.log(`  Dropping aggregate: ${proname}`);
        try {
          await client.queryObject(`DROP AGGREGATE IF EXISTS "${proname}" CASCADE`);
          console.log(`  Dropped aggregate: ${proname}`);
        } catch (error) {
          console.error(`  Failed to drop aggregate ${proname}:`, error instanceof Error ? error.message : String(error));
        }
      }
    } else {
      console.log("No aggregates found in public schema");
    }
  } catch (error) {
    console.error("Warning: Could not check for aggregates:", error instanceof Error ? error.message : String(error));
  }
}

async function dropCustomSchemas(client: Client): Promise<void> {
  const query = `
    SELECT n.nspname as schema_name, u.usename as owner
    FROM pg_namespace n
    JOIN pg_user u ON n.nspowner = u.usesysid    
    WHERE n.nspname NOT IN ('information_schema', 'pg_catalog', 'pg_toast', 'public', 'auth', 'extensions')    
    AND u.usename = current_user
    ORDER BY n.nspname;
  `;
  
  const result = await client.queryObject(query);
  
  if (result.rows.length === 0) {
    console.log("No user-owned schemas found to drop");
    return;
  }
  
  console.log(`Found ${result.rows.length} user-owned schema(s) to drop:`);
  
  for (const row of result.rows) {
    const { schema_name, owner } = row as { schema_name: string; owner: string };
    console.log(`  Dropping schema: ${schema_name} (owned by: ${owner})`);
    
    try {
      await client.queryObject(`DROP SCHEMA IF EXISTS "${schema_name}" CASCADE`);
      console.log(`  Dropped schema: ${schema_name}`);
    } catch (error) {
      console.error(`  Failed to drop schema ${schema_name}:`, error instanceof Error ? error.message : String(error));
    }
  }
}