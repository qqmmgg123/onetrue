// Vision / OCR proxy stub. OpenAI-compatible chat with image content.
// Secrets: ZHIPU_API_KEY (+ ZHIPU_BASE_URL) or VISION_API_KEY + VISION_BASE_URL
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return json({ error: "missing Authorization" }, 401);
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: { user }, error: userErr } = await supabase.auth.getUser();
    if (userErr || !user) {
      return json({ error: "unauthorized" }, 401);
    }

    const zhipuKey = Deno.env.get("ZHIPU_API_KEY") ?? "";
    const visionKey = Deno.env.get("VISION_API_KEY") ?? "";
    const apiKey = zhipuKey || visionKey;
    if (!apiKey) {
      return json({ error: "VISION/ZHIPU secrets not configured" }, 500);
    }

    const base = (
      zhipuKey
        ? (Deno.env.get("ZHIPU_BASE_URL") ??
          "https://open.bigmodel.cn/api/paas/v4")
        : (Deno.env.get("VISION_BASE_URL") ??
          "https://api.siliconflow.cn/v1")
    ).replace(/\/+$/, "");

    const body = await req.json();
    if (!body.model) {
      body.model = Deno.env.get("ZHIPU_VISION_MODEL") ?? "glm-4v-flash";
    }

    const upstream = await fetch(`${base}/chat/completions`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify(body),
    });

    const text = await upstream.text();
    return new Response(text, {
      status: upstream.status,
      headers: {
        ...corsHeaders,
        "Content-Type": upstream.headers.get("Content-Type") ??
          "application/json",
      },
    });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
