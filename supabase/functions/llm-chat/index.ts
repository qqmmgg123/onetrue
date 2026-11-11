// OpenAI-compatible chat proxy. Secrets: LLM_BASE_URL, LLM_API_KEY, LLM_MODEL (optional).
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

    const upstreamBase = (Deno.env.get("LLM_BASE_URL") ??
      "https://api.deepseek.com/v1").replace(/\/+$/, "");
    const apiKey = Deno.env.get("LLM_API_KEY") ?? "";
    if (!apiKey) {
      return json({ error: "LLM_API_KEY not configured" }, 500);
    }

    const body = await req.json();
    if (!body.model && Deno.env.get("LLM_MODEL")) {
      body.model = Deno.env.get("LLM_MODEL");
    }

    const upstream = await fetch(`${upstreamBase}/chat/completions`, {
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
