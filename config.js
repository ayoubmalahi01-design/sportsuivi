// Build-time configuration only. Set VITE_SUPABASE_URL and
// VITE_SUPABASE_PUBLISHABLE_KEY in the Cloudflare build environment.
// Never place a service_role key or database password in this file.
const CFG = {
  url: import.meta.env.VITE_SUPABASE_URL || 'https://xbjthetphqxdhwufkmly.supabase.co',
  key: import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY || ''
};
export default CFG;
