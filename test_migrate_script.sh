#!/bin/bash

# Test script for migrate --script option
# This script verifies that the migrate command with --script flag generates a non-empty migrate.sql file

set -e

echo "Testing migrate --script option..."

# Clean up any existing migrate.sql
if [ -f migrate.sql ]; then
    rm migrate.sql
    echo "Removed existing migrate.sql"
fi

# Run migrate with --script flag
echo "Running: deno task migrate --apps _core --script"
deno task migrate --apps _core --script

# Verify migrate.sql was created
if [ ! -f migrate.sql ]; then
    echo "❌ FAILED: migrate.sql was not generated"
    exit 1
fi

# Verify migrate.sql is not empty
if [ ! -s migrate.sql ]; then
    echo "❌ FAILED: migrate.sql is empty"
    exit 1
fi

# Get file size
file_size=$(wc -c < migrate.sql)
line_count=$(wc -l < migrate.sql)

echo "✓ migrate.sql generated successfully"
echo "  File size: ${file_size} bytes"
echo "  Line count: ${line_count} lines"

# Verify the file contains key elements
if ! grep -q "BEGIN;" migrate.sql; then
    echo "❌ FAILED: migrate.sql does not contain BEGIN statement"
    exit 1
fi

if ! grep -q "COMMIT;" migrate.sql; then
    echo "❌ FAILED: migrate.sql does not contain COMMIT statement"
    exit 1
fi

if ! grep -q "INSERT INTO public._versions" migrate.sql; then
    echo "❌ FAILED: migrate.sql does not contain version insert"
    exit 1
fi

if ! grep -q "NOTIFY pgrst, 'reload schema'" migrate.sql; then
    echo "❌ FAILED: migrate.sql does not contain NOTIFY statement"
    exit 1
fi

# Count NOTIFY statements - should be exactly 1
notify_count=$(grep -c "NOTIFY pgrst, 'reload schema'" migrate.sql)
if [ "$notify_count" -ne 1 ]; then
    echo "❌ FAILED: Expected 1 NOTIFY statement, found ${notify_count}"
    exit 1
fi

echo "✓ migrate.sql contains required SQL elements"
echo "  - BEGIN/COMMIT transactions"
echo "  - Version inserts"
echo "  - Single NOTIFY statement at the end"

# Test with multiple apps
echo ""
echo "Testing with multiple apps..."
rm migrate.sql

echo "Running: deno task migrate --apps nwind,test --script"
deno task migrate --apps nwind,test --script

# Verify migration comments for different apps
if ! grep -q "Migration: _core\." migrate.sql; then
    echo "❌ FAILED: migrate.sql does not contain _core migrations"
    exit 1
fi

if ! grep -q "Migration: nwind\." migrate.sql; then
    echo "❌ FAILED: migrate.sql does not contain nwind migrations"
    exit 1
fi

if ! grep -q "Migration: test\." migrate.sql; then
    echo "❌ FAILED: migrate.sql does not contain test migrations"
    exit 1
fi

echo "✓ migrate.sql contains migrations from all specified apps"

# Clean up
rm migrate.sql

echo ""
echo "✅ ALL TESTS PASSED"
echo "The migrate --script option is working correctly"
