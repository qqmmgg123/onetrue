// ASR proxy stub. Forward multipart/raw audio to upstream using secrets.
// Secrets (any one path): GROQ_API_KEY | ASR_API_KEY + ASR_BASE_URL | BAIDU_ASR_*
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

    const groqKey = Deno.env.get("GROQ_API_KEY") ?? "";
    const asrKey = Deno.env.get("ASR_API_KEY") ?? "";
    const asrBase = (Deno.env.get("ASR_BASE_URL") ??
      "https://api.siliconflow.cn/v1").replace(/\/+$/, "");
    const asrModel = Deno.env.get("ASR_MODEL") ??
      "FunAudioLLM/SenseVoiceSmall";

    if (!groqKey && !asrKey) {
      return json({
        error: "ASR secrets not configured (GROQ_API_KEY or ASR_API_KEY)",
      }, 500);
    }

    // Prefer Groq Whisper OpenAI-compatible endpoint when set.
    const upstreamUrl = groqKey
      ? "https://api.groq.com/openai/v1/audio/transcriptions"
      : `${asrBase}/audio/transcriptions`;
    const upstreamKey = groqKey || asrKey;

    const incoming = await req.formData();
    const forward = new FormData();
    for (const [k, v] of incoming.entries()) {
      forward.append(k, v);
    }
    if (!forward.has("model")) {
      forward.append(
        "model",
        groqKey
          ? (Deno.env.get("GROQ_ASR_MODEL") ?? "whisper-large-v3-turbo")
          : asrModel,
      );
    }

    const upstream = await fetch(upstreamUrl, {
      method: "POST",
      headers: { Authorization: `Bearer ${upstreamKey}` },
      body: forward,
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
