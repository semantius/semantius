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
    const [{ default: mermaid }, { init }] = await Promise.all([
        import('mermaid'),
        import('@mostlylucid/mermaid-enhancements'),
    ]);
    window.mermaid = mermaid;
    await init();
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

// https://astro.build/config
export default defineConfig({
  site: process.env.SITE_URL || 'https://www.semantius.com',
  output: 'static',
  image: {
    service: { entrypoint: 'astro/assets/services/sharp' },
    domains: ['vitejs.dev', 'upload.wikimedia.org', 'astro.build', 'pagepro.co'],
  },
  adapter: getAdapter(),
  markdown: {
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
