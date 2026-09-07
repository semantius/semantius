#!/usr/bin/env -S deno run --allow-run --allow-read --allow-write --allow-env
/**
 * Compiles the CLI into a self-contained `pg_semantius` executable.
 *
 * `deno compile --include apps` embeds every .sql file under apps/ in the
 * executable, so the binary carries the exact SQL of the release it was cut
 * from and needs neither a checkout nor Deno on the target machine. The CLI
 * reads that copy through packages/cli/assets.ts, which is why nothing in it
 * may resolve a path against the working directory.
 *
 * Usage (from anywhere; the script finds the repository root itself):
 *   deno task build-cli             # the host platform
 *   deno task build-cli:all         # every published target
 *   deno task build-cli --target aarch64-apple-darwin --out dist
 */

import { basename, resolve } from "https://deno.land/std@0.208.0/path/mod.ts";

/**
 * Asset name prefix for the compiled binaries.
 *
 * `-cli`, not plain `pg_semantius`: the same release page also carries the
 * extension's `pg_semantius--<version>.sql`, `pg_semantius.control` and the
 * PGXN archive `pg_semantius-<version>.zip`. Those three names are fixed by
 * PostgreSQL and PGXN and cannot move, so the binaries are the side that
 * disambiguates. Only the published asset name carries the suffix - the
 * installers still land the file as `pg_semantius`, which is the command.
 */
const ASSET_PREFIX = "pg_semantius-cli";

/**
 * Rust target triple -> published asset suffix. The suffixes are what the
 * installers download by name, so they are part of the release contract:
 * changing one breaks `install.sh` / `install.ps1` for everybody who already
 * has them piped into a shell.
 *
 * There is no macOS x64 entry: Apple Silicon is the only Mac target built, and
 * install.sh says so outright rather than downloading something that cannot
 * run. There is no 32-bit Windows entry either - Deno has no such target.
 */
const TARGETS: Record<string, string> = {
  "x86_64-unknown-linux-gnu": "linux-x64",
  "aarch64-unknown-linux-gnu": "linux-arm64",
  "aarch64-apple-darwin": "darwin-arm64",
  "x86_64-pc-windows-msvc": "windows-x64.exe",
  "aarch64-pc-windows-msvc": "windows-arm64.exe",
};

/**
 * `aarch64-pc-windows-msvc` is a compile target only from Deno 2.9.3 on, and
 * every target the release ships must be buildable from one runtime - a
 * release built by two different Denos is a release nobody can reproduce.
 * Refuse early and by name rather than failing on the fifth compile.
 */
const MIN_DENO = "2.9.3";

function versionAtLeast(actual: string, minimum: string): boolean {
  // Compare the release numbers only: a canary reports "2.9.3+abc1234", and
  // the suffix must not make it look older than 2.9.3.
  const parse = (v: string) =>
    v.split(/[-+]/)[0].split(".").map((part) => Number(part) || 0);
  const a = parse(actual);
  const b = parse(minimum);
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const diff = (a[i] ?? 0) - (b[i] ?? 0);
    if (diff !== 0) return diff > 0;
  }
  return true;
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function usage(): never {
  console.log(`
Usage: deno task build-cli [OPTIONS]

OPTIONS:
    --all                 Build every published target (default: the host)
    --target <TRIPLE>     Build one target; repeatable
    --out <DIR>           Output directory (default: dist)

TARGETS:
${
    Object.entries(TARGETS)
      .map(([triple, suffix]) =>
        `    ${triple.padEnd(28)} ${ASSET_PREFIX}-${suffix}`
      )
      .join("\n")
  }
`);
  Deno.exit(0);
}

async function main(): Promise<void> {
  const args = [...Deno.args];
  const targets: string[] = [];
  let outDir = "dist";
  let all = false;

  while (args.length > 0) {
    const arg = args.shift()!;
    switch (arg) {
      case "--all":
        all = true;
        break;
      case "--target": {
        const triple = args.shift();
        if (!triple) {
          console.error("--target needs a target triple");
          Deno.exit(1);
        }
        if (!(triple in TARGETS)) {
          console.error(
            `unknown target "${triple}". Known targets: ${
              Object.keys(TARGETS).join(", ")
            }`,
          );
          Deno.exit(1);
        }
        targets.push(triple);
        break;
      }
      case "--out": {
        const dir = args.shift();
        if (!dir) {
          console.error("--out needs a directory");
          Deno.exit(1);
        }
        outDir = dir;
        break;
      }
      case "-h":
      case "--help":
        usage();
        break;
      default:
        console.error(
          `unknown option: ${arg} (see deno task build-cli --help)`,
        );
        Deno.exit(1);
    }
  }

  if (!versionAtLeast(Deno.version.deno, MIN_DENO)) {
    console.error(
      `Deno ${Deno.version.deno} cannot build every released target; ` +
        `${MIN_DENO} or newer is required (aarch64-pc-windows-msvc arrived ` +
        `in ${MIN_DENO}). Upgrade with \`deno upgrade\`.`,
    );
    Deno.exit(1);
  }

  let selected: string[];
  if (all) {
    selected = Object.keys(TARGETS);
  } else if (targets.length > 0) {
    selected = targets;
  } else {
    const host = Deno.build.target;
    if (!(host in TARGETS)) {
      console.error(
        `this host (${host}) is not one of the published targets; ` +
          `pass --target <TRIPLE> or --all`,
      );
      Deno.exit(1);
    }
    selected = [host];
  }

  // The repository root, from this script's own location: the compile has to
  // run there so that the workspace deno.json is the config that resolves
  // @semantius/core, and so that `--include apps` names the real directory
  // whatever the caller's working directory happens to be.
  const repoRoot = resolve(import.meta.dirname!, "..");
  const outPath = resolve(repoRoot, outDir);
  await Deno.mkdir(outPath, { recursive: true });

  console.log(
    `Building pg_semantius with Deno ${Deno.version.deno} into ${outPath}`,
  );

  for (const triple of selected) {
    const output = resolve(outPath, `${ASSET_PREFIX}-${TARGETS[triple]}`);
    console.log(`\n== ${triple} -> ${basename(output)} ==`);

    // Permissions are baked in at compile time and cannot be granted later.
    // --allow-run is deliberately NOT among them: the only commands that spawn
    // anything are lint and format, which need a checkout and refuse in the
    // binary anyway, and a compiled CLI that can start arbitrary processes is
    // a much larger thing to hand somebody than one that cannot.
    //
    // --node-modules-dir=none: the CLI's module graph holds no npm: or node:
    // specifier at all, so node_modules contains nothing the binary could
    // need. Leaving it on makes the build depend on whether pnpm has run -
    // packages/core carries a package.json whose devDependency is typescript -
    // and walking pnpm's symlink farm overflows the compiler's own stack on
    // Windows, which fails the build outright. Off, every machine builds the
    // same binary and none of them needs an npm install first.
    const command = new Deno.Command(Deno.execPath(), {
      args: [
        "compile",
        "--frozen",
        "--node-modules-dir=none",
        "--allow-read",
        "--allow-write",
        "--allow-env",
        "--allow-net",
        "--include",
        "apps",
        "--target",
        triple,
        "--output",
        output,
        "packages/cli/cli.ts",
      ],
      cwd: repoRoot,
      stdout: "inherit",
      stderr: "inherit",
    });

    const { code } = await command.output();
    if (code !== 0) {
      // Exit 1, not `code`: a Windows crash reports something like
      // -1073741571, and Deno.exit() truncates that to a byte - which has
      // landed on 0 and reported a failed build as a successful one.
      console.error(`\ncompile failed for ${triple} (exit ${code})`);
      Deno.exit(1);
    }

    const { size } = await Deno.stat(output);
    console.log(`   ${output}  ${formatBytes(size)}`);
  }

  console.log(
    `\nBuilt ${selected.length} binar${selected.length === 1 ? "y" : "ies"}.`,
  );
}

if (import.meta.main) {
  await main();
}
