// Calls a stack's deploy hook (hueske-digital/infrastructure, docs/decisions/0037):
// a POST whose body is signed like GitHub's webhooks, HMAC-SHA256 with the
// stack's secret in X-Hub-Signature-256. The host answers 202 once the hook
// took the call; whether the deploy worked is reported to its monitoring.
import { createHmac } from "node:crypto";

const host = (process.env.INPUT_HOST ?? "").trim();
const stack = (process.env.INPUT_STACK ?? "").trim();
const secret = process.env.INPUT_SECRET ?? "";

function fail(message) {
  console.log(`::error::${message}`);
  process.exit(1);
}

// A host name with an optional port, nothing else; the stack's name as the
// host's list allows it.
if (!/^[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]{1,5})?$|^\[::1\](:[0-9]{1,5})?$/.test(host)) {
  fail("host is the wan name of the stack's host, like wan.htz1.wontfix.xyz, without https:// or a path; is the repository variable set?");
}
if (!/^[a-z][a-z0-9-]{0,31}$/.test(stack)) {
  fail("stack is the stack's name in the host's list, like kunde");
}
// Plain http only to this machine, for tests.
const local = ["localhost", "127.0.0.1", "[::1]"].includes(host.replace(/:[0-9]+$/, ""));
let target;
try {
  target = new URL(`${local ? "http" : "https"}://${host}/hooks/deploy-${stack}`);
} catch {
  fail(`host ${host} is no host name with a valid port`);
}
if (secret.length < 32) {
  fail("secret is empty or shorter than 32 characters; is the repository secret set?");
}

// What the host's webhook log shows about the caller; the hook reads none of it.
const body = JSON.stringify({
  repository: process.env.GITHUB_REPOSITORY ?? "",
  sha: process.env.GITHUB_SHA ?? "",
  run_id: process.env.GITHUB_RUN_ID ?? "",
});
const signature = "sha256=" + createHmac("sha256", secret).update(body).digest("hex");

// A wrong signature is answered with 500 by adnanh/webhook, so only a
// failed connection or a proxy's 502 to 504 is tried again.
const attempts = 3;
for (let attempt = 1; attempt <= attempts; attempt++) {
  let response, answer;
  try {
    response = await fetch(target, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Hub-Signature-256": signature },
      body,
      redirect: "error",
      signal: AbortSignal.timeout(15000),
    });
    answer = await response.text();
  } catch (error) {
    if (attempt === attempts) fail(`no answer from ${target.origin}: ${error.cause?.code ?? error.name}`);
    console.log(`no answer from ${target.origin}, trying again`);
    await new Promise((resolve) => setTimeout(resolve, 5000 * attempt));
    continue;
  }
  // One line of plain text: an answer must not start a workflow command.
  const text = answer.replace(/\s+/g, " ").replace(/::/g, ": :").trim().slice(0, 200);
  if (response.status === 202) {
    console.log(`deploy requested: ${target.pathname} answered 202 ${text}`);
    process.exit(0);
  }
  if ([502, 503, 504].includes(response.status) && attempt < attempts) {
    console.log(`${target.pathname} answered ${response.status}, trying again`);
    await new Promise((resolve) => setTimeout(resolve, 5000 * attempt));
    continue;
  }
  const hint = {
    403: "the request was not signed",
    404: `${host} has no deploy hook for ${stack}: is deploy: true in its entry there, and the host right?`,
    500: `the signature does not match: is the secret ${stack}_deploy_secret of ${host}?`,
  }[response.status];
  fail(`${target.pathname} answered ${response.status}${hint ? `, ${hint}` : ""}: ${text}`);
}
