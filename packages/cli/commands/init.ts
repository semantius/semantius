/**
 * Init command implementation
 * Initializes a new Semantius project with basic structure and files
 */

export async function initProject(): Promise<void> {
  console.log("🚀 Initializing new Semantius project...");
  
  try {
    // Create basic project structure
    await Deno.mkdir("src", { recursive: true });
    await Deno.mkdir("tests", { recursive: true });
    
    // Create basic files
    const mainContent = `// Main application entry point
export function main(): void {
  console.log("Hello from Semantius Core!");
}

if (import.meta.main) {
  main();
}
`;
    
    const testContent = `import { assertEquals } from "https://deno.land/std@0.208.0/assert/mod.ts";
import { main } from "../src/main.ts";

Deno.test("main function exists", () => {
  assertEquals(typeof main, "function");
});
`;

    const denoJsonContent = `{
  "name": "semantius",
  "version": "1.0.0",
  "description": "Semantius Core Application",
  "exports": "./src/main.ts",
  "tasks": {
    "dev": "deno run --allow-read --allow-write --allow-env src/main.ts",
    "test": "deno test --allow-read --allow-write",
    "lint": "deno lint",
    "fmt": "deno fmt"
  },
  "compilerOptions": {
    "allowJs": true,
    "lib": ["deno.window"],
    "strict": true
  }
}`;

    await Deno.writeTextFile("src/main.ts", mainContent);
    await Deno.writeTextFile("tests/main_test.ts", testContent);
    await Deno.writeTextFile("deno.json", denoJsonContent);
    
    console.log("✅ Project initialized successfully!");
    console.log("📁 Created directories: src/, tests/");
    console.log("📄 Created files: src/main.ts, tests/main_test.ts, deno.json");
    console.log("\nNext steps:");
    console.log("  deno task dev    # Run in development mode");
    console.log("  deno task test   # Run tests");
    console.log("  deno task lint   # Run linter");
    console.log("  deno task fmt    # Format code");
    
  } catch (error) {
    console.error("❌ Failed to initialize project:", error instanceof Error ? error.message : String(error));
    Deno.exit(1);
  }
}