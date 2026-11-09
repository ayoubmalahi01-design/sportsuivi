import { createClient } from '@supabase/supabase-js'
const url=import.meta.env.VITE_SUPABASE_URL
const key=import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY
export const configured=Boolean(url&&key&&!url.includes('YOUR_')&&!key.includes('YOUR_'))
export const supabase=configured?createClient(url,key,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}}):null
export const today=()=>new Date().toISOString().slice(0,10)
export const roleLabel={super_admin:'مالك المنصة',sub_admin:'مشرف الإدارة',admin:'الإدارة',coach:'مدرب'}
export const isAdmin=r=>['super_admin','sub_admin','admin'].includes(r)
export const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))
