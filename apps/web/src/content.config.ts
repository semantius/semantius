import { defineCollection } from 'astro:content';
import { z } from 'astro/zod';
import { glob } from 'astro/loaders';
import * as fs from 'node:fs';
import * as path from 'node:path';
import matter from 'gray-matter';
import {
	extractOverview,
	extractSubsetMarkdown,
	renderSubsetHtml,
} from './lib/models-extract';

const blogCollection = defineCollection({
    loader: glob({ pattern: "**/*.{md,mdx}", base: "./src/content/blog" }),
	// Type-check frontmatter using a schema
	schema: ({ image }) => z.object({
		title: z.string(),
		description: z.string(),
		pubDate: z.coerce.date(),
		updatedDate: z.coerce.date().optional(),
		heroImage: image().optional(),
        tags: z.array(z.string()).optional(),
        youtubeId: z.string().optional(),
        audioUrl: z.string().optional(),
        isVideo: z.boolean().optional().default(false),
        noindex: z.boolean().optional().default(false),
        nofollow: z.boolean().optional().default(false),
	}),
});

const docsCollection = defineCollection({
    loader: glob({ pattern: "**/*.{md,mdx}", base: "./src/content/docs" }),
    schema: z.object({
        title: z.string(),
        navTitle: z.string().optional(),
        description: z.string(),
        order: z.number().optional(),
        noindex: z.boolean().optional().default(false),
        nofollow: z.boolean().optional().default(false),
    }),
});

const changelogCollection = defineCollection({
    loader: glob({ pattern: "**/*.{md,mdx}", base: "./src/content/changelog" }),
    schema: z.object({
        version: z.string(),
        title: z.string(),
        description: z.string(),
        pubDate: z.coerce.date(),
        type: z.enum(['major', 'feature', 'security', 'fix', 'improvement', 'planned', 'other']).default('feature'),
        isSecurity: z.boolean().optional().default(false),
        detailsUrl: z.string().optional(),
        migrationUrl: z.string().optional(),
        noindex: z.boolean().optional().default(false),
        nofollow: z.boolean().optional().default(false),
    }),
});

// Wraps the standard `glob` loader to enrich each model entry with values
// derived from the markdown body once at collection-build time, instead of
// re-extracting them on every page render. Pages just read `data.overview` and
// `data.subsetHtml` like any other frontmatter field.
// Models live at /models in the repo root (two levels above apps/web).
const baseModelsGlob = glob({ pattern: '**/*.{md,mdx}', base: '../../models' });
const modelsCollection = defineCollection({
    loader: {
        name: 'models',
        load: async (ctx) => {
            await baseModelsGlob.load(ctx);
            for (const [id, entry] of ctx.store.entries()) {
                const e = entry as {
                    body?: string;
                    data: Record<string, unknown>;
                    filePath?: string;
                    rendered?: unknown;
                    deferredRender?: boolean;
                };
                const body: string = e.body ?? '';
                const overview = extractOverview(body);
                const subsetMarkdown = extractSubsetMarkdown(body);
                const subsetHtml = renderSubsetHtml(subsetMarkdown);
                const newData = await ctx.parseData({
                    id,
                    data: { ...e.data, overview, subsetHtml },
                    filePath: e.filePath,
                });
                // Use a fresh digest — `store.set` is a no-op when the digest
                // matches what the inner glob loader already wrote, so the
                // derived fields would otherwise never reach the store.
                ctx.store.set({
                    id,
                    data: newData,
                    body: e.body,
                    filePath: e.filePath,
                    digest: ctx.generateDigest(JSON.stringify(newData)),
                    rendered: e.rendered as never,
                    deferredRender: e.deferredRender,
                });
            }
        },
    },
    schema: z.object({
        artifact: z.string().optional(),
        system_name: z.string(),
        system_slug: z.string(),
        domain: z.string().optional(),
        naming_mode: z.string().optional(),
        created_at: z.coerce.date(),
        description: z.string().optional(),
        initial_request: z.string().optional(),
        noindex: z.boolean().optional().default(false),
        nofollow: z.boolean().optional().default(false),
        // Derived by the loader from the markdown body.
        overview: z.string().optional(),
        subsetHtml: z.string().optional(),
    }),
});

// Skills live at /skills in the repo root (two levels above apps/web).
// Each skill folder contains SKILL.md (technical agent spec) and README.mdx
// (human-friendly overview). The collection loads README.mdx as the primary
// renderable entry so that render() yields the README content on skill pages.
// The custom loader also reads SKILL.md via gray-matter to merge technical
// metadata (name, semantic_model, generated_from) and stores the SKILL.md body
// in the skillBody field for the raw-skill view at /skills/[slug]/skill.
const baseSkillsGlob = glob({ pattern: '*/README.mdx', base: '../../skills' });
const skillsCollection = defineCollection({
    loader: {
        name: 'skills',
        load: async (ctx) => {
            await baseSkillsGlob.load(ctx);
            for (const [id, entry] of ctx.store.entries()) {
                const e = entry as {
                    body?: string;
                    data: Record<string, unknown>;
                    filePath?: string;
                    rendered?: unknown;
                    deferredRender?: boolean;
                };
                // Read the sibling SKILL.md to get technical metadata.
                let skillData: Record<string, unknown> = {};
                let skillBody = '';
                if (e.filePath) {
                    const skillFilePath = path.join(path.dirname(e.filePath), 'SKILL.md');
                    if (fs.existsSync(skillFilePath)) {
                        const raw = fs.readFileSync(skillFilePath, 'utf-8');
                        const parsed = matter(raw);
                        skillData = parsed.data;
                        skillBody = parsed.content.trim();
                    }
                }
                const mergedData = {
                    // README.mdx frontmatter: human-friendly title and description.
                    title: e.data.title,
                    description: e.data.description,
                    // SKILL.md frontmatter: technical metadata.
                    name: skillData.name,
                    semantic_model: skillData.semantic_model,
                    generated_from: skillData.generated_from,
                    noindex: skillData.noindex ?? false,
                    nofollow: skillData.nofollow ?? false,
                    // SKILL.md body stored for rendering on the raw-skill page.
                    skillBody,
                };
                const newData = await ctx.parseData({ id, data: mergedData, filePath: e.filePath });
                ctx.store.set({
                    id,
                    data: newData,
                    body: e.body,
                    filePath: e.filePath,
                    digest: ctx.generateDigest(JSON.stringify(newData)),
                    rendered: e.rendered as never,
                    deferredRender: e.deferredRender,
                });
            }
        },
    },
    schema: z.object({
        title: z.string(),
        description: z.string(),
        name: z.string().optional(),
        semantic_model: z.string().optional(),
        generated_from: z.string().optional(),
        noindex: z.boolean().optional().default(false),
        nofollow: z.boolean().optional().default(false),
        skillBody: z.string().optional(),
    }),
});

export const collections = {
	'blog': blogCollection,
    'docs': docsCollection,
    'changelog': changelogCollection,
    'models': modelsCollection,
    'skills': skillsCollection,
};
