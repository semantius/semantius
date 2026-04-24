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

/**
 * Convert format value to JSON Schema type(s)
 * Mimics the logic from format_to_json_type PostgreSQL function
 */
function formatToJsonType(format: string): string {
  // Special case: json format maps to json for simplicity
  if (format === 'json') {
    return 'json';
  }
  
  // Single type mappings
  if (['int32', 'int64', 'integer', 'reference'].includes(format)) {
    return 'integer';
  }
  
  if (['float', 'double', 'number'].includes(format)) {
    return 'number';
  }
  
  if (format === 'boolean') {
    return 'boolean';
  }
  
  if (format === 'array') {
    return 'array';
  }
  
  if (format === 'object') {
    return 'object';
  }
  
  if (format === 'null') {
    return 'null';
  }
  
  // Default to string for all other formats
  return 'string';
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
      
      markdown += `## Entity: ${entity.table_name}\n\n`;
      
      if (entity.description) {
        markdown += `${entity.description}\n\n`;
      }
      
      // Query fields for 'entities' table to dynamically build entity metadata
      const entityFieldsResult = await client.queryObject<FieldRecord>(
        "SELECT * FROM fields WHERE table_name = 'entities' AND field_name NOT IN ('created_at', 'updated_at') ORDER BY field_order"
      );
      
      // Entity metadata table
      markdown += `| field_name | label | value |\n`;
      markdown += `|------------|-------|-------|\n`;
      
      // Build rows dynamically from entities table fields
      for (const field of entityFieldsResult.rows) {
        const fieldValue = entity[field.field_name as keyof EntityRecord];
        let displayValue: string;
        
        if (fieldValue === null || fieldValue === undefined || fieldValue === '') {
          displayValue = '-';
        } else if (typeof fieldValue === 'boolean') {
          displayValue = String(fieldValue);
        } else if (field.field_name === 'table_name' || field.field_name === 'view_permission' || 
                   field.field_name === 'edit_permission' || field.field_name === 'id_column' || 
                   field.field_name === 'label_column') {
          displayValue = `\`${fieldValue}\``;
        } else {
          displayValue = String(fieldValue);
        }
        
        markdown += `| ${field.field_name} | ${field.title} | ${displayValue} |\n`;
      }
      
      markdown += '\n';
      
      // Query field metadata to determine which columns to display
      const fieldMetadataResult = await client.queryObject<FieldRecord>(
        "SELECT * FROM fields WHERE table_name = 'fields' ORDER BY field_order"
      );
      
      // Build list of columns to display (exclude internal/redundant fields)
      // Add computed 'type' column between 'description' and 'format'
      const baseColumns = fieldMetadataResult.rows
        .filter(f => !['id', 'table_name', 'created_at', 'updated_at'].includes(f.field_name))
        .map(f => f.field_name);
      
      const displayColumns: string[] = [];
      for (const col of baseColumns) {
        displayColumns.push(col);
        if (col === 'description') {
          displayColumns.push('type'); // Insert computed type column after description
        }
      }
      
      // Query fields for this entity
      const fieldsResult = await client.queryObject<FieldRecord>(
        "SELECT * FROM fields WHERE table_name = $1 ORDER BY field_order",
        [entity.table_name]
      );
      
      console.log(`  Found ${fieldsResult.rows.length} fields`);
      
      // Fields table
      markdown += "### Fields\n\n";
      
      // Build header row dynamically
      markdown += "| " + displayColumns.join(" | ") + " |\n";
      markdown += "|" + displayColumns.map(() => "------------").join("|") + "|\n";
      
      // Build data rows dynamically
      for (const field of fieldsResult.rows) {
        // Skip created_at and updated_at fields
        if (field.field_name === 'created_at' || field.field_name === 'updated_at') {
          continue;
        }
        
        const pkMarker = field.is_pk ? " 🔑" : "";
        const ctypeMarker = field.ctype ? ` (${field.ctype})` : "";
        
        const values = displayColumns.map(colName => {
          // Special handling for computed 'type' column
          if (colName === 'type') {
            return formatToJsonType(field.format);
          }
          
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
