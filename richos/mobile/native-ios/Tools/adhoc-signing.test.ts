// Tools/adhoc-signing.ts against a fake App Store Connect: no request leaves this Mac.
//
//   node --test richos/mobile/native-ios/Tools/adhoc-signing.test.ts
import * as NodeAssert from "node:assert/strict";
import * as NodeCrypto from "node:crypto";
import { describe, it } from "node:test";

import { ensureAdHoc, profileProblem } from "./adhoc-signing.ts";
import type { Deps, ProfileFacts } from "./adhoc-signing.ts";

const TEAM = "ABCDEFGHIJ";
const UDID = "00000000-00000000AAAABBBB";
const CERT_DER = Buffer.from("the distribution certificate");
const CERT_SHA1 = NodeCrypto.createHash("sha1").update(CERT_DER).digest("hex").toUpperCase();
const NOW = Date.parse("2026-10-04T12:00:00Z");
const BUNDLE = "dev.richos.connect.perf";
const IDS = [BUNDLE, `${BUNDLE}.notification-service`, `${BUNDLE}.share`];

type Call = { method: string; path: string; body?: unknown };

/** A fake account. Profile content is a JSON of ProfileFacts, so `decode` is JSON.parse. */
function account(options: { push?: boolean; profiles?: Record<string, unknown>[]; certificates?: Record<string, unknown>[] } = {}) {
  const calls: Call[] = [];
  let created = 0;
  const profiles = [...(options.profiles ?? [])];
  const facts = (identifier: string, extra: Partial<ProfileFacts> = {}): ProfileFacts => ({
    uuid: `00000000-0000-0000-0000-00000000000${created}`, name: `RichOS ad hoc ${identifier}`, appId: `${TEAM}.${identifier}`,
    team: TEAM, aps: identifier === BUNDLE ? "production" : null, devices: [UDID], certificates: [CERT_SHA1],
    expires: "2027-09-23T22:22:34Z", ...extra,
  });
  const deps: Deps = {
    async request(path, method = "GET", body) {
      calls.push({ method, path, body });
      const url = new URL(path, "https://api.appstoreconnect.apple.com");
      if (url.pathname === "/v1/bundleIds" && method === "GET") {
        const want = url.searchParams.get("filter[identifier]")!;
        // The API's filter also returns longer identifiers; the tool must pick the exact one.
        return { data: IDS.filter((id) => id.startsWith(want)).map((id) => ({ id: `B-${id}`, type: "bundleIds", attributes: { identifier: id } })) };
      }
      if (url.pathname.endsWith("/bundleIdCapabilities")) {
        return { data: options.push === false ? [] : [{ id: "C1", type: "bundleIdCapabilities", attributes: { capabilityType: "PUSH_NOTIFICATIONS" } }] };
      }
      if (url.pathname === "/v1/bundleIdCapabilities") return { data: { id: "C2", type: "bundleIdCapabilities", attributes: {} } };
      if (url.pathname === "/v1/certificates") {
        return { data: options.certificates ?? [{ id: "CERT", type: "certificates", attributes: { name: "Apple Distribution", certificateContent: CERT_DER.toString("base64"), expirationDate: "2027-09-23" } }] };
      }
      if (url.pathname === "/v1/devices") return { data: [{ id: "DEV", type: "devices", attributes: { udid: UDID.toLowerCase(), status: "ENABLED", name: "iPhone" } }] };
      if (url.pathname === "/v1/profiles" && method === "GET") {
        const name = url.searchParams.get("filter[name]");
        return { data: profiles.filter((p) => (p.attributes as { name: string }).name === name) };
      }
      if (url.pathname === "/v1/profiles" && method === "POST") {
        created++;
        const identifier = String((body as { data: { relationships: { bundleId: { data: { id: string } } } } }).data.relationships.bundleId.data.id).slice(2);
        return { data: { id: `P${created}`, type: "profiles", attributes: { profileContent: Buffer.from(JSON.stringify(facts(identifier))).toString("base64") } } };
      }
      if (method === "DELETE") return undefined;
      throw new Error(`unexpected ${method} ${path}`);
    },
    identities: () => [CERT_SHA1],
    decode: (content) => JSON.parse(content.toString("utf8")) as ProfileFacts,
    install: (uuid) => `/Volumes/E1TB/x/${uuid}.mobileprovision`,
    now: () => NOW,
  };
  return { deps, calls, facts };
}

const ARGS = { bundle: BUNDLE, udid: UDID, team: TEAM, out: "/Volumes/E1TB/x" };

describe("ad hoc signing", () => {
  it("makes one ad hoc profile per App ID with the keychain's certificate and the phone, production push on the app", async () => {
    const { deps, calls } = account();
    const result = await ensureAdHoc(ARGS, deps);
    NodeAssert.deepEqual(Object.keys(result.profiles), IDS);
    NodeAssert.equal(result.profiles[BUNDLE].aps, "production");
    const posts = calls.filter((c) => c.method === "POST" && c.path === "/v1/profiles");
    NodeAssert.equal(posts.length, 3);
    for (const post of posts) {
      const data = (post.body as { data: { attributes: { profileType: string }; relationships: Record<string, { data: unknown }> } }).data;
      NodeAssert.equal(data.attributes.profileType, "IOS_APP_ADHOC");
      NodeAssert.deepEqual(data.relationships.certificates.data, [{ type: "certificates", id: "CERT" }]);
      NodeAssert.deepEqual(data.relationships.devices.data, [{ type: "devices", id: "DEV" }]);
    }
    NodeAssert.equal(calls.some((c) => c.path === "/v1/bundleIdCapabilities"), false, "push was already on: nothing written");
  });

  it("turns Push Notifications on for the app's App ID when it is off", async () => {
    const { deps, calls } = account({ push: false });
    const result = await ensureAdHoc(ARGS, deps);
    const added = calls.find((c) => c.path === "/v1/bundleIdCapabilities");
    NodeAssert.equal((added?.body as { data: { attributes: { capabilityType: string } } }).data.attributes.capabilityType, "PUSH_NOTIFICATIONS");
    NodeAssert.ok(result.done.includes(`turned on Push Notifications for ${BUNDLE}`));
  });

  it("reuses an ACTIVE profile that already fits, and replaces an invalid one", async () => {
    const { facts } = account();
    const fits = { id: "OLD1", type: "profiles", attributes: { name: `RichOS ad hoc ${BUNDLE}`, profileState: "ACTIVE", profileType: "IOS_APP_ADHOC",
      profileContent: Buffer.from(JSON.stringify(facts(BUNDLE))).toString("base64") } };
    const invalid = { id: "OLD2", type: "profiles", attributes: { name: `RichOS ad hoc ${IDS[1]}`, profileState: "INVALID", profileType: "IOS_APP_ADHOC",
      profileContent: Buffer.from(JSON.stringify(facts(IDS[1]))).toString("base64") } };
    const { deps, calls } = account({ profiles: [fits, invalid] });
    const result = await ensureAdHoc(ARGS, deps);
    NodeAssert.equal(result.profiles[BUNDLE].how, "reused");
    NodeAssert.equal(result.profiles[IDS[1]].how, "created");
    NodeAssert.deepEqual(calls.filter((c) => c.method === "DELETE").map((c) => c.path), ["/v1/profiles/OLD2"]);
  });

  it("refuses when no distribution certificate of the account has its key in this Mac's keychain", async () => {
    const { deps } = account({ certificates: [{ id: "OTHER", type: "certificates", attributes: { certificateContent: Buffer.from("x").toString("base64") } }] });
    await NodeAssert.rejects(ensureAdHoc(ARGS, deps), /No Apple Distribution certificate .* private key in this Mac's keychain/u);
  });

  it("names what is wrong with a profile's own content", () => {
    const want = { team: TEAM, identifier: BUNDLE, udid: UDID, cert: CERT_SHA1, push: true, now: NOW };
    const good = account().facts(BUNDLE);
    NodeAssert.equal(profileProblem(good, want), null);
    NodeAssert.match(String(profileProblem({ ...good, aps: "development" }, want)), /development, not production/u);
    NodeAssert.match(String(profileProblem({ ...good, devices: [] }, want)), /does not include the phone/u);
    NodeAssert.match(String(profileProblem({ ...good, certificates: ["0"] }, want)), /distribution certificate/u);
    NodeAssert.match(String(profileProblem({ ...good, expires: "2026-10-04T18:00:00Z" }, want)), /expires/u);
    NodeAssert.match(String(profileProblem({ ...good, appId: `${TEAM}.dev.richos.connect` }, want)), /is for/u);
  });
});
