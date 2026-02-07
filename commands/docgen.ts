/**
 * Docgen command implementation
 * Generates schema.md documentation from entities metadata
 */

import { Client } from "@postgres";

interface EntityRecord {
  table_name: string;
  singular: string;
  plural: string;
  singular_label: string;
  plural_label: string;
  icon_url: string;
  description: string;
  module_id: number;
  view_permission: string;
  edit_permission: string;
  id_column: string;
  label_column: string;
  managed: boolean;
  searchable: boolean;
  created_at: string;
  updated_at: string;
}

interface FieldRecord {
  id: string;
  table_name: string;
  field_name: string;
  title: string;
  description: string;
  format: string;
  is_pk: boolean;
  is_nullable: boolean;
  default_value: string;
  field_order: number;
  input_type: string;
  width: string;
  ctype: string;
  is_core: boolean;
  searchable: boolean;
  enum_values: any;
  reference_table: string;
  reference_delete_mode: string;
  created_at: string;
  updated_at: string;
}

export async function docgenCommand(databaseUrl: string): Promise<void> {
  console.log("Generating schema.md documentation...");
  
  const client = new Client(databaseUrl);
  
  try {
    await client.connect();
    console.log("Connected to database");
    
    // Query entities for module_id = 1 (_core module)
    const entitiesResult = await client.queryObject<EntityRecord>(
      "SELECT * FROM entities WHERE module_id = 1 ORDER BY table_name"
    );
    
    console.log(`Found ${entitiesResult.rows.length} entities for _core module`);
    
    // Build markdown document
    let markdown = "# Database Schema Documentation\n\n";
    markdown += "This document describes the database schema for the _core module.\n\n";
    markdown += `**Generated:** ${new Date().toISOString()}\n\n`;
    markdown += "---\n\n";
    
    // Process each entity
    for (const entity of entitiesResult.rows) {
      console.log(`Processing entity: ${entity.table_name}`);
      
      markdown += `## ${entity.singular_label}\n\n`;
      markdown += `**Table Name:** \`${entity.table_name}\`\n\n`;
      
      if (entity.description) {
        markdown += `**Description:** ${entity.description}\n\n`;
      }
      
      // Entity metadata table
      markdown += "### Entity Metadata\n\n";
      markdown += "| Property | Value |\n";
      markdown += "|----------|-------|\n";
      markdown += `| Table Name | \`${entity.table_name}\` |\n`;
      markdown += `| Singular | ${entity.singular} |\n`;
      markdown += `| Plural | ${entity.plural} |\n`;
      markdown += `| Singular Label | ${entity.singular_label} |\n`;
      markdown += `| Plural Label | ${entity.plural_label} |\n`;
      if (entity.icon_url) {
        markdown += `| Icon URL | ${entity.icon_url} |\n`;
      }
      markdown += `| Module ID | ${entity.module_id} |\n`;
      markdown += `| View Permission | \`${entity.view_permission}\` |\n`;
      markdown += `| Edit Permission | \`${entity.edit_permission}\` |\n`;
      markdown += `| ID Column | \`${entity.id_column}\` |\n`;
      markdown += `| Label Column | \`${entity.label_column}\` |\n`;
      markdown += `| Managed | ${entity.managed} |\n`;
      markdown += `| Searchable | ${entity.searchable} |\n`;
      
      // Query field metadata to determine which columns to display
      const fieldMetadataResult = await client.queryObject<FieldRecord>(
        "SELECT * FROM fields WHERE table_name = 'fields' ORDER BY field_order"
      );
      
      // Build list of columns to display (exclude internal/redundant fields)
      const displayColumns = fieldMetadataResult.rows
        .filter(f => !['id', 'table_name', 'created_at', 'updated_at'].includes(f.field_name))
        .map(f => f.field_name);
      
      // Query fields for this entity
      const fieldsResult = await client.queryObject<FieldRecord>(
        "SELECT * FROM fields WHERE table_name = $1 ORDER BY field_order",
        [entity.table_name]
      );
      
      console.log(`  Found ${fieldsResult.rows.length} fields`);
      
      // Fields table
      markdown += "\n### Fields\n\n";
      
      // Build header row dynamically
      markdown += "| " + displayColumns.join(" | ") + " |\n";
      markdown += "|" + displayColumns.map(() => "------------").join("|") + "|\n";
      
      // Build data rows dynamically
      for (const field of fieldsResult.rows) {
        const pkMarker = field.is_pk ? " 🔑" : "";
        const ctypeMarker = field.ctype ? ` (${field.ctype})` : "";
        
        const values = displayColumns.map(colName => {
          const value = field[colName as keyof FieldRecord];
          
          // Special formatting for field_name (first column)
          if (colName === 'field_name') {
            return `\`${value}\`${pkMarker}${ctypeMarker}`;
          }
          
          // Special formatting for enum_values (JSON)
          if (colName === 'enum_values') {
            return value ? JSON.stringify(value) : "-";
          }
          
          // Handle empty strings and null values
          if (value === null || value === undefined || value === '') {
            return "-";
          }
          
          return String(value);
        });
        
        markdown += "| " + values.join(" | ") + " |\n";
      }
      
      markdown += "\n---\n\n";
    }
    
    // Write to schema.md file
    const outputPath = "./schema.md";
    await Deno.writeTextFile(outputPath, markdown);
    
    console.log(`Documentation generated successfully: ${outputPath}`);
    console.log(`Total entities documented: ${entitiesResult.rows.length}`);
    
  } catch (error) {
    console.error("Failed to generate documentation:", error instanceof Error ? error.message : String(error));
    Deno.exit(1);
  } finally {
    try {
      await client.end();
      console.log("Database connection closed");
    } catch (_closeError) {
      console.warn("Warning: Could not close connection properly");
    }
  }
}
