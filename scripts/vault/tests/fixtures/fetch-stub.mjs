// Preloaded (`node --import`) by backfill-source-identity.test.mjs: no live network.
// raw.githubusercontent.com 404s (what a private repo does to an unauthenticated
// fetch); any other URL throws so an unexpected network path fails loud.
globalThis.fetch = async (url) => {
  if (String(url).startsWith("https://raw.githubusercontent.com/")) {
    return new Response("404: Not Found", { status: 404 });
  }
  throw new Error(`fetch-stub: unexpected network call to ${url}`);
};
