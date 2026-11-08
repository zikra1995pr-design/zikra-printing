-- مطبعة ذكرى | الخطوة التالية بعد إنشاء 14 جدول و48 سياسة الإدارة.
-- شغّل هذا الملف داخل SQL Editor في مشروع Zikra-Printing فقط.
-- لا يعيد إنشاء الجداول ولا يلمس مشروع الإبداع القديم.
BEGIN;

-- واجهة فحص صلاحية المدير الموجودة داخل كود المتجر القديم
CREATE OR REPLACE FUNCTION public.store_is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.admins AS a
    WHERE a.user_id = (SELECT auth.uid())
  );
$$;
REVOKE ALL ON FUNCTION public.store_is_admin() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.store_is_admin() TO authenticated;

-- بيانات التحويل مخصصة لعرضها للزبائن فقط (وليست كلمات مرور).
-- طلبات الزبائن وتفاصيلها لا تُتاح للقراءة العامة.
GRANT SELECT ON public.store_payment_settings TO anon, authenticated;
DROP POLICY IF EXISTS zikra_public_payment_settings ON public.store_payment_settings;
CREATE POLICY zikra_public_payment_settings
ON public.store_payment_settings
FOR SELECT TO anon, authenticated
USING (id = 1);

-- وصل التحويل يُرفع إلى Bucket خاص ولا يُعرض علناً.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('payment-receipts', 'payment-receipts', false, 5242880,
  ARRAY['image/jpeg','image/png','image/webp']::text[])
ON CONFLICT (id) DO UPDATE SET
  public = false,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS zikra_receipts_upload ON storage.objects;
CREATE POLICY zikra_receipts_upload ON storage.objects
FOR INSERT TO anon, authenticated
WITH CHECK (
  bucket_id = 'payment-receipts'
  AND name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$'
);

DROP POLICY IF EXISTS zikra_receipts_admin_read ON storage.objects;
CREATE POLICY zikra_receipts_admin_read ON storage.objects
FOR SELECT TO authenticated
USING (
  bucket_id = 'payment-receipts'
  AND (SELECT private.is_zikra_admin())
);

-- تنفيذ الطلب عبر دالة فقط: يتحقق من المنتجات والأسعار الحالية من قاعدة البيانات
-- ويحسب التوصيل من جهة الخادم، ولا يثق بالسعر القادم من المتصفح.
CREATE OR REPLACE FUNCTION public.store_checkout_with_payment(
  p_name text,
  p_phone text,
  p_province text,
  p_district text,
  p_address text,
  p_notes text,
  p_items jsonb,
  p_payment_method text,
  p_receipt_path text
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_entry jsonb;
  v_product public.store_products%ROWTYPE;
  v_id bigint;
  v_qty integer;
  v_subtotal bigint := 0;
  v_delivery integer;
  v_total bigint;
  v_order_id bigint;
  v_lines jsonb := '[]'::jsonb;
  v_item jsonb;
  v_payment_enabled boolean;
BEGIN
  IF char_length(trim(coalesce(p_name,''))) NOT BETWEEN 2 AND 100 THEN
    RAISE EXCEPTION 'الاسم يجب أن يكون من 2 إلى 100 حرف';
  END IF;
  IF coalesce(p_phone,'') !~ '^[+0-9() -]{7,25}$' THEN
    RAISE EXCEPTION 'رقم الهاتف غير صحيح';
  END IF;
  IF char_length(trim(coalesce(p_province,''))) NOT BETWEEN 2 AND 50
    OR char_length(trim(coalesce(p_district,''))) NOT BETWEEN 2 AND 100
    OR char_length(trim(coalesce(p_address,''))) NOT BETWEEN 5 AND 300 THEN
    RAISE EXCEPTION 'تحقق من المحافظة والمنطقة والعنوان';
  END IF;
  IF char_length(coalesce(p_notes,'')) > 1000 THEN
    RAISE EXCEPTION 'الملاحظات طويلة جداً';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'قائمة المنتجات غير صالحة';
  END IF;
  IF jsonb_array_length(p_items) < 1 OR jsonb_array_length(p_items) > 30 THEN
    RAISE EXCEPTION 'عدد أنواع المنتجات غير مسموح';
  END IF;
  IF coalesce(p_payment_method,'') NOT IN ('cod','transfer') THEN
    RAISE EXCEPTION 'طريقة الدفع غير صحيحة';
  END IF;

  IF p_payment_method = 'transfer' THEN
    SELECT enabled AND length(trim(transfer_details)) > 0
    INTO v_payment_enabled
    FROM public.store_payment_settings WHERE id=1;
    IF coalesce(v_payment_enabled,false) IS NOT TRUE THEN
      RAISE EXCEPTION 'الدفع بالتحويل غير مفعل حالياً';
    END IF;
    IF coalesce(p_receipt_path,'') !~
      '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$'
      OR NOT EXISTS (
        SELECT 1 FROM storage.objects
        WHERE bucket_id='payment-receipts' AND name=p_receipt_path
      ) THEN
      RAISE EXCEPTION 'وصل التحويل غير موجود';
    END IF;
  ELSE
    IF p_receipt_path IS NOT NULL THEN
      RAISE EXCEPTION 'وصل الدفع غير مطلوب عند الاستلام';
    END IF;
  END IF;

  FOR v_entry IN SELECT value FROM jsonb_array_elements(p_items)
  LOOP
    IF jsonb_typeof(v_entry) <> 'object'
      OR coalesce(v_entry->>'id','') !~ '^[1-9][0-9]{0,17}$'
      OR coalesce(v_entry->>'qty','') !~ '^[1-9][0-9]?$' THEN
      RAISE EXCEPTION 'تفاصيل منتج غير صحيحة';
    END IF;
    v_id := (v_entry->>'id')::bigint;
    v_qty := (v_entry->>'qty')::integer;
    SELECT * INTO v_product
    FROM public.store_products
    WHERE id=v_id AND active=true AND price>=0;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'أحد المنتجات لم يعد متاحاً';
    END IF;
    v_subtotal := v_subtotal + (v_product.price::bigint * v_qty);
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'product_id',v_id,'name',v_product.name,
      'quantity',v_qty,'unit_price',v_product.price
    ));
  END LOOP;

  -- مطابق لاحتساب أجور الشحن في index.html: البصرة 3000 والبقية 5000.
  v_delivery := CASE WHEN trim(p_province)='البصرة' THEN 3000 ELSE 5000 END;
  v_total := v_subtotal + v_delivery;
  IF v_total > 2147483647 THEN
    RAISE EXCEPTION 'قيمة الطلب أكبر من الحد المسموح';
  END IF;

  INSERT INTO public.store_orders
    (customer_name,phone,province,district,address,notes,status,total)
  VALUES
    (trim(p_name),trim(p_phone),trim(p_province),trim(p_district),
     trim(p_address),coalesce(p_notes,''),'قيد الانتظار',v_total::integer)
  RETURNING id INTO v_order_id;

  FOR v_item IN SELECT value FROM jsonb_array_elements(v_lines)
  LOOP
    INSERT INTO public.store_order_items
      (order_id,product_id,product_name,quantity,unit_price)
    VALUES
      (v_order_id,(v_item->>'product_id')::bigint,v_item->>'name',
       (v_item->>'quantity')::integer,(v_item->>'unit_price')::integer);
  END LOOP;

  INSERT INTO public.store_order_payments
    (order_id,method,payment_status,receipt_path)
  VALUES (v_order_id,p_payment_method,'pending',p_receipt_path);

  RETURN v_order_id;
END;
$$;

REVOKE ALL ON FUNCTION public.store_checkout_with_payment(
  text,text,text,text,text,text,jsonb,text,text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.store_checkout_with_payment(
  text,text,text,text,text,text,jsonb,text,text
) TO anon, authenticated;

COMMIT;

-- بعد نجاح التنفيذ، يجب أن تظهر نتيجة تحتوي على الدالتين.
SELECT routine_name
FROM information_schema.routines
WHERE routine_schema='public'
AND routine_name IN ('store_is_admin','store_checkout_with_payment')
ORDER BY routine_name;
