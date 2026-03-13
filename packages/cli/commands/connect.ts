/**
 * Connect command implementation
 * Tests database connection using provided DATABASE_URL
 */

import { Client } from "@postgres";

export async function connectDatabaseConnection(databaseUrl: string): Promise<void> {
  console.log("Testing database connection...");
  
  try {
    console.log("Found DATABASE_URL in environment");
    
    // Parse the connection string to validate format
    let parsedUrl: URL;
    try {
      parsedUrl = new URL(databaseUrl);
    } catch (error) {
      console.error("Invalid DATABASE_URL format:", error instanceof Error ? error.message : String(error));
      console.log("Expected format: postgresql://username:password@host:port/database");
      Deno.exit(1);
    }
    
    if (parsedUrl.protocol !== "postgresql:") {
      console.error("DATABASE_URL must use postgresql:// protocol");
      console.log(`Found protocol: ${parsedUrl.protocol}`);
      Deno.exit(1);
    }
    
    console.log(`Connecting to: ${parsedUrl.hostname}:${parsedUrl.port || 5432}`);
    console.log(`Database: ${parsedUrl.pathname.slice(1)}`);
    console.log(`User: ${parsedUrl.username}`);
    
    // Test the actual PostgreSQL connection
    await testPostgreSQLConnection(databaseUrl);
    
    console.log("Database connection test passed!");
    console.log("Your PostgreSQL database is accessible and ready to use");
    
  } catch (error) {
    console.error("Database connection test failed:", error instanceof Error ? error.message : String(error));
    console.log("\nTroubleshooting tips:");
    console.log("  - Check if DATABASE_URL is correctly set in .env.local");
    console.log("  - Verify database server is running and accessible");
    console.log("  - Confirm username/password are correct");
    console.log("  - Check if SSL settings are required");
    Deno.exit(1);
  }
}

async function testPostgreSQLConnection(databaseUrl: string): Promise<void> {
  console.log("Attempting PostgreSQL connection...");
  
  const client = new Client(databaseUrl);
  
  try {
    // Connect to the database
    await client.connect();
    console.log("PostgreSQL connection established");
    
    // Test a simple query to verify the connection works
    const result = await client.queryObject("SELECT version() as version, current_database() as database, current_user as user");
    
    if (result.rows.length > 0) {
      const row = result.rows[0] as { version: string; database: string; user: string };
      console.log("Database query successful");
      console.log(`PostgreSQL Version: ${row.version.split(' ')[0]} ${row.version.split(' ')[1]}`);
      console.log(`Connected Database: ${row.database}`);
      console.log(`Connected User: ${row.user}`);
    }
    
  } catch (error) {
    if (error instanceof Error) {
      if (error.message.includes("authentication failed")) {
        throw new Error("Authentication failed. Check your username and password in DATABASE_URL.");
      } else if (error.message.includes("database") && error.message.includes("does not exist")) {
        throw new Error("Database does not exist. Check the database name in DATABASE_URL.");
      } else if (error.message.includes("Connection refused")) {
        throw new Error("Connection refused. Database server may not be running or network issues.");
      } else if (error.message.includes("SSL")) {
        throw new Error("SSL connection error. Check SSL configuration in DATABASE_URL.");
      } else {
        throw new Error(`PostgreSQL connection failed: ${error.message}`);
      }
    } else {
      throw new Error(`PostgreSQL connection failed: ${String(error)}`);
    }
  } finally {
    // Always close the connection
    try {
      await client.end();
      console.log("Connection closed properly");
    } catch (_closeError) {
      console.warn("Warning: Could not close connection properly");
    }
  }
}