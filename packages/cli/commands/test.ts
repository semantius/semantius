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
  executionTimeMs: number;
}

interface TapReporter {
  start(): void;
  test(result: TestResult): boolean; // returns false if failFast should stop execution
  finish(results: TestResult[]): void;
}

class DefaultReporter implements TapReporter {
  private totalTests = 0;
  private totalPassed = 0;
  private totalFailed = 0;
  private totalPlanned = 0;
  private filesWithErrors = 0;
  private failFast: boolean;

  constructor(failFast = false) {
    this.failFast = failFast;
  }

  start(): void {
    console.log("TAP version 13");
  }

  test(result: TestResult): boolean {
    // SQL execution errors are reported but don't abort the test run
    if (result.errors.length > 0) {
      console.log(`# FATAL ERROR in ${result.filename}`);
      console.log(`# Error: ${result.errors[0]}`);
      this.filesWithErrors++;
      this.totalFailed++; // Count the file error as a failure
      return !this.failFast;
    }

    console.log(`# ${basename(result.filename)}, ${result.executionTimeMs} ms`);

    const lines = result.content.split('\n').filter(line => line.trim());
    let testNum = 0;
    let fileFailed = false;

    for (const line of lines) {
      if (line.startsWith('1..')) {
        console.log(line);
        const planned = parseInt(line.substring(3));
        this.totalPlanned += planned;
      } else if (line.match(/^(not )?ok \d+/)) {
        testNum++;
        console.log(line);
        if (line.startsWith('ok')) {
          this.totalPassed++;
        } else {
          this.totalFailed++;
          fileFailed = true;
        }
      } else if (line.startsWith('#')) {
        console.log(line);
      }
    }
    this.totalTests += result.executed;
    return !(this.failFast && fileFailed);
  }

  finish(results: TestResult[]): void {
    const totalExecutionMs = results.reduce((sum, result) => sum + result.executionTimeMs, 0);
    
    console.log(`\n# Tests: ${this.totalTests}`);
    console.log(`# Passed: ${this.totalPassed}`);
    console.log(`# Failed: ${this.totalFailed}`);
    if (this.filesWithErrors > 0) {
      console.log(`# Files with errors: ${this.filesWithErrors}`);
    }
    
    // Validate that all planned tests actually ran
    if (this.totalPlanned > 0 && this.totalTests !== this.totalPlanned) {
      console.log(`# WARNING: Test count mismatch!`);
      console.log(`#   Planned: ${this.totalPlanned} tests`);
      console.log(`#   Executed: ${this.totalTests} tests`);
      console.log(`#   Missing: ${this.totalPlanned - this.totalTests} tests`);
    }
    
    console.log(`# Total execution time: ${totalExecutionMs} ms`);
    
    const hasFailures = this.totalFailed > 0 || this.filesWithErrors > 0;
    const hasMissingTests = this.totalPlanned > 0 && this.totalTests !== this.totalPlanned;
    const overallResult = (hasFailures || hasMissingTests) ? "FAIL" : "PASS";
    console.log(`# Result: ${overallResult}`);
    
    if (hasFailures || hasMissingTests) {
      Deno.exit(1);
    }
  }
}

class TapSpecReporter implements TapReporter {
  private totalPlanned = 0;
  private totalExecuted = 0;
  private totalPassed = 0;
  private totalFailed = 0;
  private currentTest = 0;
  private filesWithErrors = 0;
  private skippedFiles: string[] = [];
  private failFast: boolean;

  constructor(failFast = false) {
    this.failFast = failFast;
  }

  start(): void {
    console.log("\n");
  }

  test(result: TestResult): boolean {
    console.log(`\n  ${basename(result.filename)}, ${result.executionTimeMs} ms`);

    // SQL execution errors are reported but don't abort the test run
    if (result.errors.length > 0) {
      console.error(`    ✗ FATAL: SQL execution failed`);
      console.error(`    Error: ${result.errors[0]}`);
      this.filesWithErrors++;
      this.totalFailed++;
      this.skippedFiles.push(basename(result.filename));
      return !this.failFast;
    }

    const lines = result.content.split('\n').filter(line => line.trim());
    let planned = 0;
    let executed = 0;
    let fileFailed = false;

    for (const line of lines) {
      if (line.startsWith('1..')) {
        planned = parseInt(line.substring(3));
      } else if (line.match(/^(not )?ok \d+/)) {
        this.currentTest++;
        executed++;
        const parts = line.split(' - ');
        const testName = parts[1] || `test ${this.currentTest}`;

        if (line.startsWith('ok')) {
          console.log(`    ✓ ${testName}`);
          this.totalPassed++;
        } else {
          console.log(`    ✗ ${testName}`);
          this.totalFailed++;
          fileFailed = true;
        }
      } else if (line.startsWith('#')) {
        // Filter out pgTAP internal messages and show clean diagnostic output
        const isFailedTestMessage = line.toLowerCase().includes('failed test');
        const isLooksLikeMessage = line.toLowerCase().includes('looks like you failed');

        if (!isFailedTestMessage && !isLooksLikeMessage) {
          // Remove leading # and extra spaces, then display
          const cleanLine = line.substring(1).trim();
          if (cleanLine) {
            console.log(`    ${cleanLine}`);
          }
        }
      }
    }

    // Check for plan vs execution mismatch per file
    if (planned > 0 && executed !== planned) {
      console.log(`    ✗ Test plan mismatch: planned ${planned} tests but ran ${executed}`);
      this.totalFailed++;
      fileFailed = true;
    }

    this.totalPlanned += planned;
    this.totalExecuted += executed;
    return !(this.failFast && fileFailed);
  }

  finish(results: TestResult[]): void {
    const totalExecutionMs = results.reduce((sum, result) => sum + result.executionTimeMs, 0);
    
    console.log(`\n\n  ${this.totalPassed} passing`);
    if (this.totalFailed > 0) {
      console.log(`  ${this.totalFailed} failing`);
    }
    
    // Check for overall plan vs execution mismatch
    if (this.totalPlanned > 0 && this.totalExecuted !== this.totalPlanned) {
      console.log(`\n  ⚠️  WARNING: Test count mismatch!`);
      console.log(`      Planned: ${this.totalPlanned} tests`);
      console.log(`      Executed: ${this.totalExecuted} tests`);
      console.log(`      Missing: ${this.totalPlanned - this.totalExecuted} tests`);
    }
    
    // Report files with errors
    if (this.filesWithErrors > 0) {
      console.log(`\n  ⚠️  ${this.filesWithErrors} file(s) had SQL execution errors:`);
      for (const file of this.skippedFiles) {
        console.log(`      - ${file}`);
      }
    }
    
    console.log(`\n  Total execution time: ${totalExecutionMs} ms`);
    
    // Exit with failure if there are failed tests, plan mismatches, or file errors
    const hasFailures = this.totalFailed > 0 || this.filesWithErrors > 0;
    const hasMissingTests = this.totalPlanned > 0 && this.totalExecuted !== this.totalPlanned;
    
    if (hasFailures || hasMissingTests) {
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
    
    // Check if pgtap schema exists first
    const schemaCheck = await this.client.queryObject(`
      SELECT schema_name 
      FROM information_schema.schemata 
      WHERE schema_name = 'pgtap'
    `);
    
    if (schemaCheck.rows.length === 0) {
      console.error("FATAL: pgtap schema not found");
      console.error("Run: deno task migrate test");
      console.error("This will install the pgtap testing framework");
      Deno.exit(1);
    }
    
    // Set search path to include pgtap and public schemas
    await this.client.queryArray("SET search_path TO public, pgtap;");
  }

  async disconnect(): Promise<void> {
    await this.client.end();
  }

  async runTest(filePath: string): Promise<TestResult> {
    const startTime = performance.now();
    
    try {
      const content = await Deno.readTextFile(filePath);
      const result = await this.client.queryArray(content);
      
      const executionTimeMs = Math.round(performance.now() - startTime);
      
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
        errors: [],
        executionTimeMs
      };
    } catch (error) {
      const executionTimeMs = Math.round(performance.now() - startTime);
      
      // When there's an error, we can't determine the planned count from the file
      // so we return planned: 0, executed: 0 to indicate failure
      const errorMessage = error instanceof Error ? error.message : String(error);
      return {
        filename: filePath,
        content: `# Failed to execute test: ${errorMessage}`,
        passed: false,
        planned: 0,
        executed: 0,
        errors: [errorMessage],
        executionTimeMs
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
      const shouldContinue = this.reporter.test(result);
      if (!shouldContinue) {
        console.log("\n# Stopping after first failure (--failfast)");
        break;
      }
    }

    this.reporter.finish(results);
    return results;
  }
}



export async function testCommand(databaseUrl: string, tapFlag?: boolean, failFast = false): Promise<void> {
  console.log("Running test command...");

  // Use plain TAP reporter when --tap flag is provided, otherwise use pretty formatted reporter
  const reporter = tapFlag ? new DefaultReporter(failFast) : new TapSpecReporter(failFast);
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


