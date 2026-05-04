import fs from 'node:fs';
import path from 'node:path';
import type { APIRoute } from 'astro';
import { getCollection } from 'astro:content';

export const prerender = true;

export async function getStaticPaths() {
  const models = await getCollection('models');
  return models.map((model) => ({ params: { id: model.id } }));
}

export const GET: APIRoute = ({ params }) => {
  // Models live at /models in the repo root (two levels above apps/web).
  const filePath = path.resolve('../../models', `${params.id}.md`);
  const body = fs.readFileSync(filePath, 'utf-8');
  return new Response(body, {
    headers: { 'Content-Type': 'text/markdown; charset=utf-8' },
  });
};
