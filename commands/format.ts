/**
 * Format command implementation
 * Formats code using Deno's built-in formatter
 */

export async function formatProject(): Promise<void> {
  console.log("🎨 Formatting code...");
  
  try {
    const command = new Deno.Command("deno", {
      args: ["fmt"],
    });
    
    const { code } = await command.output();
    
    if (code === 0) {
      console.log("✅ Code formatted successfully!");
    } else {
      console.error("❌ Formatting failed!");
      Deno.exit(1);
    }
    
  } catch (error) {
    console.error("❌ Formatter error:", error instanceof Error ? error.message : String(error));
    Deno.exit(1);
  }
}