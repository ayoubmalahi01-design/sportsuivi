# دليل إعداد ونشر Sport Performance

## متغيرات الاتصال

لا توجد بيانات اتصال ثابتة داخل الكود. اضبط في بيئة بناء Cloudflare:

- `VITE_SUPABASE_URL`: رابط مشروع Supabase الصحيح الذي يحتوي قاعدة Sport Performance.
- `VITE_SUPABASE_PUBLISHABLE_KEY`: مفتاح Publishable/anon المخصص للمتصفح.

لا تضع مفتاح `service_role` أو كلمة مرور قاعدة البيانات داخل التطبيق أو ZIP.

## ترقية قاعدة البيانات

راجع ونفّذ فقط `supabase/migrations/20261112_production_upgrade.sql` بعد التأكد من أن المخطط الحالي يطابق المتطلبات المذكورة في الملف. لا تستخدم ملفات المرجع أو ملفات Migration القديمة المنقولة إلى `docs/legacy`.

## بناء التطبيق

```bash
npm install
npm run build
```

## نشر Cloudflare Workers Static Assets

```bash
npx wrangler deploy
```

راجع `wrangler.jsonc` وتأكد من اسم Worker الصحيح. يجب أن يكون البناء قد تم بعد ضبط متغيرات Vite؛ تغيير متغيرات Cloudflare بعد إنتاج `dist` لا يغير القيم التي بُنيت داخل ملفات JavaScript.

## تثبيت PWA

يجب أن يكون الموقع على HTTPS وأن يعمل `manifest.webmanifest` و`sw.js`:

- Android/Chrome: قائمة المتصفح ← تثبيت التطبيق.
- iOS/Safari: مشاركة ← إضافة إلى الشاشة الرئيسية.
- Desktop/Chrome أو Edge: Install من شريط العنوان أو القائمة.

هذه PWA قابلة للتثبيت، وليست APK موقّعًا أو تطبيق متجر.
