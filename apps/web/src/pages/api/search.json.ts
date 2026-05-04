import { getCollection } from 'astro:content';

export const prerender = false;

export async function GET() {
  const docs = await getCollection('docs').catch(() => []);
  const blog = await getCollection('blog').catch(() => []);
  const models = await getCollection('models').catch(() => []);

  const results = [];

  for (const doc of docs) {
    if (doc.data?.noindex) continue;
    const slug = doc.id.replace(/\.[^/.]+$/, "");
    results.push({
      title: doc.data?.title || slug,
      description: doc.data?.description || '',
      url: `/docs/${slug}`,
      body: doc.body || ''
    });
  }

  for (const post of blog) {
    if (post.data?.noindex) continue;
    const slug = post.id.replace(/\.[^/.]+$/, "");
    results.push({
      title: post.data?.title || slug,
      description: post.data?.description || '',
      url: `/blog/${slug}`,
      body: post.body || ''
    });
  }

  for (const model of models) {
    if (model.data?.noindex) continue;
    results.push({
      title: model.data.system_name,
      description: model.data.description || '',
      url: `/models/${model.data.system_slug}`,
      body: model.body || ''
    });
  }

  return new Response(JSON.stringify(results), {
    status: 200,
    headers: {
      'Content-Type': 'application/json',
      'Cache-Control': 'public, max-age=86400'
    }
  });
}
