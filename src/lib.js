import { createClient } from '@supabase/supabase-js'
import CFG from '../config.js'
const url=import.meta.env.VITE_SUPABASE_URL || CFG.url
const key=import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY || CFG.key
export const configured=Boolean(url&&key&&!url.includes('YOUR_')&&!key.includes('YOUR_'))
export const supabase=configured?createClient(url,key,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}}):null
export const today=()=>{const d=new Date();return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`}
export const roleLabel={super_admin:'مالك المنصة',sub_admin:'مشرف الإدارة',admin:'الإدارة',coach:'مدرب'}
export const isAdmin=r=>['super_admin','sub_admin','admin'].includes(r)
export const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))
