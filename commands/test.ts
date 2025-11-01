/**
 * Test command implementation
 * execute pgTAP tests from tests/ directory
 */


import { Client } from "@postgres";
import { walk } from "@std/fs/walk";
import { basename } from "@std/path";


interface TestResult {
  filename: string;
  content: string;
  passed: boolean;
  planned: number;
  executed: number;
  errors: string[];
}

interface TapReporter {
  start(): void;
  test(result: TestResult): void;
  finish(results: TestResult[]): void;
}

class DefaultReporter implements TapReporter {
  private totalTests = 0;
  private totalPassed = 0;
  private totalFailed = 0;

  start(): void {
    console.log("TAP version 13");
  }

  test(result: TestResult): void {
    const lines = result.content.split('\n').filter(line => line.trim());
    let testNum = 0;
    
    for (const line of lines) {
      if (line.startsWith('1..')) {
        console.log(line);
      } else if (line.match(/^(not )?ok \d+/)) {
        testNum++;
        console.log(line);
        if (line.startsWith('ok')) {
          this.totalPassed++;
        } else {
          this.totalFailed++;
        }
      } else if (line.startsWith('#')) {
        console.log(line);
      }
    }
    this.totalTests += result.executed;
  }

  finish(results: TestResult[]): void {
    console.log(`\n# Tests: ${this.totalTests}`);
    console.log(`# Passed: ${this.totalPassed}`);
    console.log(`# Failed: ${this.totalFailed}`);
    
    const overallResult = this.totalFailed === 0 ? "PASS" : "FAIL";
    console.log(`# Result: ${overallResult}`);
    
    if (this.totalFailed > 0) {
      Deno.exit(1);
    }
  }
}

class TapSpecReporter implements TapReporter {
  private totalTests = 0;
  private totalPassed = 0;
  private totalFailed = 0;
  private currentTest = 0;

  start(): void {
    console.log("\n");
  }

  test(result: TestResult): void {
    const lines = result.content.split('\n').filter(line => line.trim());
    let planned = 0;
    
    console.log(`\n  ${basename(result.filename)}`);
    
    for (const line of lines) {
      if (line.startsWith('1..')) {
        planned = parseInt(line.substring(3));
      } else if (line.match(/^(not )?ok \d+/)) {
        this.currentTest++;
        const parts = line.split(' - ');
        const testName = parts[1] || `test ${this.currentTest}`;
        
        if (line.startsWith('ok')) {
          console.log(`    ✓ ${testName}`);
          this.totalPassed++;
        } else {
          console.log(`    ✗ ${testName}`);
          this.totalFailed++;
        }
      }
    }
    this.totalTests += planned;
  }

  finish(results: TestResult[]): void {
    console.log(`\n\n  ${this.totalPassed} passing`);
    if (this.totalFailed > 0) {
      console.log(`  ${this.totalFailed} failing`);
    }
    
    if (this.totalFailed > 0) {
      Deno.exit(1);
    }
  }
}

class PgTest {
  private client: Client;
  private reporter: TapReporter;

  constructor(connectionString: string, reporter: TapReporter) {
    this.client = new Client(connectionString);
    this.reporter = reporter;
  }

  async connect(): Promise<void> {
    await this.client.connect();
    // Set search path to include pgtap and public schemas
    await this.client.queryArray("SET search_path TO pgtap, public;");
  }

  async disconnect(): Promise<void> {
    await this.client.end();
  }

  async runTest(filePath: string): Promise<TestResult> {
    try {
      const content = await Deno.readTextFile(filePath);
      const result = await this.client.queryArray(content);
      
      // Extract TAP output from the result
      const tapOutput = result.rows.map(row => row[0]).join('\n');
      
      const planned = this.extractPlannedTests(tapOutput);
      const executed = this.countExecutedTests(tapOutput);
      const passedCount = this.countPassedTests(tapOutput);
      const passed = passedCount === planned && executed === planned;
      
      return {
        filename: filePath,
        content: tapOutput,
        passed,
        planned,
        executed,
        errors: []
      };
    } catch (error) {
      // When there's an error, we can't determine the planned count from the file
      // so we return planned: 0, executed: 0 to indicate failure
      const errorMessage = error instanceof Error ? error.message : String(error);
      return {
        filename: filePath,
        content: `# Failed to execute test: ${errorMessage}`,
        passed: false,
        planned: 0,
        executed: 0,
        errors: [errorMessage]
      };
    }
  }

  private extractPlannedTests(output: string): number {
    const planMatch = output.match(/1\.\.(\d+)/);
    return planMatch ? parseInt(planMatch[1]) : 0;
  }

  private countExecutedTests(output: string): number {
    const testLines = output.split('\n').filter(line => 
      line.match(/^(not )?ok \d+/)
    );
    return testLines.length;
  }

  private countPassedTests(output: string): number {
    const testLines = output.split('\n').filter(line => 
      line.match(/^ok \d+/)
    );
    return testLines.length;
  }

  private isTestPassed(output: string): boolean {
    const planned = this.extractPlannedTests(output);
    const executed = this.countExecutedTests(output);
    const passed = this.countPassedTests(output);
    return planned > 0 && executed === planned && passed === planned;
  }

  async runTests(testDir: string): Promise<TestResult[]> {
    const results: TestResult[] = [];
    
    this.reporter.start();
    
    for await (const entry of walk(testDir, { exts: [".sql"], includeDirs: false })) {
      const result = await this.runTest(entry.path);
      results.push(result);
      this.reporter.test(result);
    }
    
    this.reporter.finish(results);
    return results;
  }
}



export async function testCommand(databaseUrl: string, tapFlag?: boolean): Promise<void> {
  console.log("Running test command...");
  
  // Use plain TAP reporter when --tap flag is provided, otherwise use pretty formatted reporter
  const reporter = tapFlag ? new DefaultReporter() : new TapSpecReporter();
  const pgTest = new PgTest(databaseUrl, reporter);

  try {
    await pgTest.connect();
    console.log(`Connected to PostgreSQL at ${databaseUrl.replace(/\/\/[^@]+@/, '//***:***@')}`);
    
    const _results = await pgTest.runTests("./apps/test/tests");
    
    await pgTest.disconnect();
    console.log("Test command completed!");
  } catch (error) {
    console.error("Test command failed:", error instanceof Error ? error.message : String(error));
    Deno.exit(1);
  }
}


