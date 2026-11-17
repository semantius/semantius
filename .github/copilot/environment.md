# GitHub Copilot Agent Environment Configuration

## Required Environment Variables

The agent needs access to the following environment variable:

```bash
DATABASE_URL=postgresql://postgres:DD3ZR7NPSIu9dzVw@db.feuwllkajpvgwqovfjyh.supabase.co:5432/postgres
```

## Setup Instructions

### For Copilot Environment Secret (Best Option):
1. Go to repository Settings → "Copilot" → "Environments" 
2. Click "Add environment secret"
3. Name: `DATABASE_URL`
4. Secret: `postgresql://postgres:DD3ZR7NPSIu9dzVw@db.feuwllkajpvgwqovfjyh.supabase.co:5432/postgres`

### Alternative - Repository Secrets:
1. Go to repository Settings → "Secrets and variables" → "Actions"
2. Click "New repository secret"
3. Name: `DATABASE_URL`
4. Secret: Your database URL

### Agent Access:
- Copilot environment secret provides direct access to the agent
- Secret is encrypted and hidden from logs
- Specific to Copilot execution context

### For Codespaces:
- The devcontainer.json is configured to inherit DATABASE_URL from local environment
- Set DATABASE_URL in your Codespaces secrets

### Agent Execution Context:
- Agent runs in GitHub's cloud environment
- Accesses environment variables through GitHub's secure variable system
- `DATABASE_URL` names a remote database: never run `deno task dropall`
  against it, nor `retest` or `reset`, which drop everything first

## Safety Notes:
- The rules for agents are in [AGENTS.md](../../AGENTS.md).
- Tests run on the local pgdocker containers (`./pgdocker/pg-cli-retest.sh`,
  `./pgdocker/pg-ext-retest.sh`), never on a remote database.
- After a release, migrations are forward only and additive only.