import { defineConfig } from 'astro/config';
import sitemap from "@astrojs/sitemap";
import react from "@astrojs/react";
import mdx from "@astrojs/mdx";
import cloudflare from "@astrojs/cloudflare";
import tailwindcss from '@tailwindcss/vite';
import compress from "astro-compress";
import rehypeSlug from 'rehype-slug';
import rehypeAutolinkHeadings from 'rehype-autolink-headings';
import fs from 'node:fs';
import path from 'node:path';
import matter from 'gray-matter';

/**
 * Remark plugin that injects a "Use <Skill>" heading and install command box
 * before the "## Semantic model" section in each skill README.mdx.
 * The injection happens in-memory during the remark AST transformation; the
 * source MDX files are never modified.
 */
function remarkSkillInstallCommand() {
    const COPY_SVG = '<svg class="command-icon-copy" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path></svg>';
    const CHECK_SVG = '<svg class="command-icon-check" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="20 6 9 17 4 12"></polyline></svg>';

    return function transformer(tree, vfile) {
        const filePath = vfile.path || (vfile.history && vfile.history[0]) || '';
        // Only apply to skill README files (e.g. .../skills/product-roadmap/README.mdx)
        const match = filePath.match(/skills[\\/]([\w-]+)[\\/]README\.mdx$/i);
        if (!match) return;

        const slug = match[1];
        const command = `npx skills add https://github.com/semantius/semantius/tree/main/skills/${slug}`;

        // Title: prefer frontmatter data set by Astro's remark pipeline; fall
        // back to parsing the raw file source, then to the slug.
        let title = slug;
        const fm = vfile.data && vfile.data.astro && vfile.data.astro.frontmatter;
        if (fm && fm.title) {
            title = fm.title;
        } else if (vfile.value) {
            const titleMatch = String(vfile.value).match(/^title:\s*(.+)$/m);
            if (titleMatch) title = titleMatch[1].replace(/^['"]|['"]$/g, '').trim();
        }

        // Locate the "## Semantic model" heading in the mdast
        let insertIndex = -1;
        for (let i = 0; i < tree.children.length; i++) {
            const node = tree.children[i];
            if (node.type === 'heading' && node.depth === 2) {
                const text = node.children
                    .filter(function (c) { return c.type === 'text'; })
                    .map(function (c) { return c.value; })
                    .join('');
                if (text === 'Semantic model') {
                    insertIndex = i;
                    break;
                }
            }
        }
        if (insertIndex === -1) return;

        // Build the command box as a raw HTML node so it uses the existing
        // .command CSS without importing the Command.astro component.
        const escapedCommand = command.replace(/&/g, '&amp;').replace(/"/g, '&quot;');
        const commandHtml = `<div class="command not-prose group is-shell"><code class="command-text">${command}</code><button type="button" class="command-copy" data-command="${escapedCommand}" aria-label="Copy command">${COPY_SVG}${CHECK_SVG}<span class="command-copy-label">Copy</span></button></div>`;

        // Insert a "## Use <title>" heading (mdast node, so rehypeSlug +
        // rehypeAutolinkHeadings will process it normally) followed by the
        // raw HTML command box.
        tree.children.splice(insertIndex, 0,
            {
                type: 'heading',
                depth: 2,
                children: [{ type: 'text', value: 'Use ' + title }],
            },
            {
                type: 'html',
                value: commandHtml,
            }
        );
    };
}

/**
 * Custom Astro integration that replaces astro-mermaid.
 * Converts mermaid fenced code blocks to <pre class="mermaid"> elements
 * without HTML-escaping the content (keeps < and > as raw characters so
 * the diagram source can be copy-pasted directly from view-source).
 * Pan/zoom and toolbar are added client-side via @mostlylucid/mermaid-enhancements.
 */
function mermaidEnhanced() {
    // Remark plugin: walk the mdast tree and replace code[lang=mermaid] nodes
    // with raw HTML nodes. Node value is inserted verbatim; no entity encoding.
    function remarkMermaid() {
        return function transformer(tree) {
            function walk(node, parent, index) {
                if (
                    node.type === 'code' &&
                    node.lang === 'mermaid' &&
                    parent !== null &&
                    index >= 0
                ) {
                    // Insert the raw mermaid source verbatim. No HTML-escaping
                    // so < and > are preserved as-is for easy view-source
                    // copy-paste. Content comes from repo .md files (developer-
                    // controlled), not from user input, so no XSS risk here.
                    parent.children[index] = {
                        type: 'html',
                        value: `<pre class="mermaid">${node.value}</pre>`,
                    };
                } else if (node.children) {
                    for (let i = 0; i < node.children.length; i++) {
                        walk(node.children[i], node, i);
                    }
                }
            }
            walk(tree, null, -1);
        };
    }

    return {
        name: 'mermaid-enhanced',
        hooks: {
            'astro:config:setup': ({ config, updateConfig, injectScript }) => {
                updateConfig({
                    markdown: {
                        remarkPlugins: [
                            ...(config.markdown?.remarkPlugins || []),
                            remarkMermaid,
                        ],
                    },
                    vite: {
                        optimizeDeps: {
                            include: ['mermaid'],
                        },
                    },
                });

                // Client-side script: loads mermaid globally then initialises
                // @mostlylucid/mermaid-enhancements (pan/zoom, toolbar, theme).
                injectScript('page', `
const hasMermaid = () =>
    document.querySelectorAll('pre.mermaid, div.mermaid').length > 0;

async function initMermaidEnhanced() {
    if (!hasMermaid()) return;
    try {
        const [{ default: mermaid }, { init }] = await Promise.all([
            import('mermaid'),
            import('@mostlylucid/mermaid-enhancements'),
        ]);
        window.mermaid = mermaid;
        await init();
    } catch (err) {
        console.error('[mermaid-enhanced] Failed to initialise:', err);
    }
}

initMermaidEnhanced();
document.addEventListener('astro:after-swap', () => initMermaidEnhanced());
`);
            },
        },
    };
}

// Helper to find noindex URLs
function getNoIndexUrls() {
  const urls = new Set();
  const contentDir = path.resolve('./src/content');
  const pagesDir = path.resolve('./src/pages');

  function scanDir(dir, callback) {
    if (!fs.existsSync(dir)) return;
    const files = fs.readdirSync(dir);
    for (const file of files) {
      const fullPath = path.join(dir, file);
      const stat = fs.statSync(fullPath);
      if (stat.isDirectory()) {
        scanDir(fullPath, callback);
      } else {
        callback(fullPath);
      }
    }
  }

  // Scan Content Collections
  scanDir(contentDir, (filePath) => {
    if (filePath.endsWith('.md') || filePath.endsWith('.mdx')) {
      try {
        const fileContent = fs.readFileSync(filePath, 'utf-8');
        const { data } = matter(fileContent);
        if (data.noindex) {
          let relative = path.relative(contentDir, filePath);
          let urlPath = relative.replace(/\.(md|mdx)$/, '');
          urlPath = urlPath.replace(/\\/g, '/');
          if (!urlPath.startsWith('/')) urlPath = '/' + urlPath;
          urls.add(urlPath);
          urls.add(urlPath + '/');
        }
      } catch (e) {
        console.warn(`Error parsing frontmatter for ${filePath}`, e);
      }
    }
  });

  // Scan Pages
  scanDir(pagesDir, (filePath) => {
    if (filePath.endsWith('.astro')) {
      const content = fs.readFileSync(filePath, 'utf-8');
      if (content.includes('noindex={true}')) {
        let relative = path.relative(pagesDir, filePath);
        let urlPath = relative.replace(/\.astro$/, '');
        urlPath = urlPath.replace(/\\/g, '/');

        if (urlPath.endsWith('/index')) {
          urlPath = urlPath.replace(/\/index$/, '') || '/';
        } else if (urlPath === 'index') {
          urlPath = '/';
        }

        if (!urlPath.startsWith('/')) urlPath = '/' + urlPath;
        urls.add(urlPath);
        urls.add(urlPath + '/');
      }
    }
  });

  return Array.from(urls);
}

const noIndexUrls = getNoIndexUrls();
console.log('Excluding URLs from sitemap:', noIndexUrls);

const DEFAULT_LOCALE = "en";

// Heading anchor links: appends a small chain icon after every heading; styled
// to fade in on hover (see apps/web/src/styles/typography.css .heading-anchor).
const autolinkHeadingsOptions = {
  behavior: 'append',
  properties: {
    className: ['heading-anchor'],
    ariaLabel: 'Permalink to this heading',
  },
  content: {
    type: 'element',
    tagName: 'svg',
    properties: {
      xmlns: 'http://www.w3.org/2000/svg',
      width: '14',
      height: '14',
      viewBox: '0 0 24 24',
      fill: 'none',
      stroke: 'currentColor',
      strokeWidth: '2',
      strokeLinecap: 'round',
      strokeLinejoin: 'round',
      ariaHidden: 'true',
    },
    children: [
      { type: 'element', tagName: 'path', properties: { d: 'M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71' }, children: [] },
      { type: 'element', tagName: 'path', properties: { d: 'M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71' }, children: [] },
    ],
  },
};

import vercel from "@astrojs/vercel";
import netlify from "@astrojs/netlify";
import node from "@astrojs/node";
import process from "node:process";

// ... other imports

// Adapter selection strategy
function getAdapter() {
  const adapter = process.env.ADAPTER || 'node';

  switch (adapter) {
    case 'vercel':
      return vercel({
        webAnalytics: { enabled: true }
      });
    case 'netlify':
      return netlify();
    case 'cloudflare':
      return cloudflare({
        imageService: 'compile',
        platformProxy: {
          enabled: true,
        },
        runtime: {
          mode: 'advanced',
          type: 'worker',
          nodejsCompat: true,
        },
      });
    case 'node':
    default:
      return node({
        mode: 'standalone'
      });
  }
}

// Legacy flat docs URLs (kept around because they were the only scheme before
// the nested-folder refactor). 301 to the new nested URL so external links and
// blog posts keep working.
const docsLegacyRedirects = {
  '/docs/models-overview': '/docs/models',
  '/docs/models-structure': '/docs/models/structure',
  '/docs/models-create': '/docs/models/create',
  '/docs/models-templates': '/docs/models/templates',
  '/docs/models-deploy': '/docs/models/deploy',
  '/docs/models-optimize': '/docs/models/optimize',
  '/docs/mcp-connectors-overview': '/docs/mcp-connectors',
  '/docs/mcp-connectors-installation': '/docs/mcp-connectors/installation',
  '/docs/agent-skills-overview': '/docs/agent-skills',
  '/docs/agent-skills-installation': '/docs/agent-skills/installation',
  '/docs/cli-overview': '/docs/cli',
  '/docs/cli-command': '/docs/cli/command',
  '/docs/cli-skill': '/docs/cli/skill',
};

// https://astro.build/config
export default defineConfig({
  site: process.env.SITE_URL || 'https://www.semantius.com',
  output: 'static',
  redirects: docsLegacyRedirects,
  image: {
    service: { entrypoint: 'astro/assets/services/sharp' },
    domains: ['vitejs.dev', 'upload.wikimedia.org', 'astro.build', 'pagepro.co'],
  },
  adapter: getAdapter(),
  markdown: {
    remarkPlugins: [
      remarkSkillInstallCommand,
    ],
    rehypePlugins: [
      rehypeSlug,
      [rehypeAutolinkHeadings, autolinkHeadingsOptions],
    ],
  },
  integrations: [
    sitemap({
      filter: (page) => {
        const url = new URL(page);
        const pathname = url.pathname;
        return !noIndexUrls.includes(pathname);
      }
    }),
    react(),
    mdx({
      rehypePlugins: [
        rehypeSlug,
        [rehypeAutolinkHeadings, autolinkHeadingsOptions],
      ],
    }),
    mermaidEnhanced(),
    (await import("astro-compress")).default({ Image: false, JavaScript: true, HTML: false })
  ],
  vite: {
    plugins: [tailwindcss()],
    define: {
      'import.meta.env.DEFAULT_LOCALE': JSON.stringify(DEFAULT_LOCALE)
    }
  },
});
