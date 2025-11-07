# Agent Execution Guidelines

## Safe Test Environment
- This project uses a throwaway test database
- The agent MUST execute database operations to verify functionality
- The database URL in `.env.local` is safe for agent execution

## Required Agent Actions

### After Any Database Changes
1. **ALWAYS execute**: `deno task dropall --confirm`
2. **ALWAYS execute**: `deno task migrate --apps test --verbose`  
3. **ALWAYS execute**: `deno task test`
4. **VERIFY**: All tests pass before completing the task

### After Any CLI Changes
1. Test the new command functionality
2. Ensure it integrates with existing workflow
3. Verify error handling works correctly

### After Any Test Changes
1. Execute the full test cycle
2. Verify new tests run successfully
3. Ensure no existing tests are broken

## Agent Permissions
- ✅ Execute deno commands
- ✅ Run database migrations
- ✅ Execute pgTAP tests
- ✅ Drop and recreate database
- ✅ Read/write all project files
- ✅ Access .env.local for database connection

## Success Criteria
The agent has successfully completed a task when:
1. All requested changes are implemented
2. Full test cycle executes without errors
3. All pgTAP tests pass
4. No breaking changes introduced

**Remember**: This is a prototype environment - break things, fix them, and verify with tests!