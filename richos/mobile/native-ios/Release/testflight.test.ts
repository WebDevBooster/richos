// Tests for Release/testflight.ts, against a fake App Store Connect. No request leaves this Mac.
//
//   node --test richos/mobile/native-ios/Release/testflight.test.ts
//
// ADOPTED from T3 Code (https://github.com/pingdotgg/t3code) at
// 2eb6a53343ffb4ce747617746ee85433115ad18f, `scripts/swift-testflight.test.ts`, MIT License,
// Copyright (c) 2026 T3 Tools Inc. Ported from vite-plus/test to node:test (RichOS has no vitest)
// with the same cases, plus RichOS's own: internal-only publishing, the bundle identifier from the
// private file, and the refusal of a credentials file inside a git working tree.
import * as NodeAssert from "node:assert/strict";
import * as NodeChildProcess from "node:child_process";
import * as NodeCrypto from "node:crypto";
import * as NodeFS from "node:fs";
import * as NodeFSP from "node:fs/promises";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import { describe, it } from "node:test";

import {
  createTestFlightClient,
  insideGitWorkTree,
  makeAppStoreToken,
  parseTestFlightArgs,
  parseTestFlightEnv,
  readTestFlightEnv,
  validateUploadMetadata,
  withTemporaryPrivateKey,
} from "./testflight.ts";

const BUNDLE = "dev.richos.connect";
const keys = NodeCrypto.generateKeyPairSync("ec", { namedCurve: "prime256v1" });
const encodedKey = Buffer.from(keys.privateKey.export({ type: "pkcs8", format: "pem" })).toString("base64");
const envSource = `# Synthetic test credentials, never used with Apple.
RICHOS_IOS_ASC_KEY_ID="TESTKEY123"
RICHOS_IOS_ASC_ISSUER_ID=00000000-0000-0000-0000-000000000001
RICHOS_IOS_ASC_PRIVATE_KEY_BASE64="${encodedKey}"
RICHOS_IOS_ASC_APP_ID=12345
RICHOS_IOS_ASC_BUNDLE_ID=${BUNDLE}
RICHOS_IOS_ASC_PUBLIC_GROUP_ID=public
RICHOS_IOS_ASC_INTERNAL_GROUP_ID=internal
`;
const internalOnlySource = envSource.replace("RICHOS_IOS_ASC_PUBLIC_GROUP_ID=public\n", "");
const { config } = parseTestFlightEnv(envSource);
// The version under test is the one the app ships: MARKETING_VERSION in project.yml.
const VERSION = /^\s*MARKETING_VERSION:\s*"([^"]+)"/mu.exec(
  NodeFS.readFileSync(new URL("../project.yml", import.meta.url), "utf8"),
)?.[1];
if (!VERSION) throw new Error("project.yml sets no MARKETING_VERSION");
const selection = { build: "46", version: VERSION };
const notes = "Fix attachment imports and keep the keyboard open during dictation.";
const linkage = (type: string, id: string) => ({ data: { type, id } });

function mockServer(
  options: {
    bundleId?: string;
    groupAppId?: string;
    buildAppId?: string;
    buildExists?: boolean;
    processingState?: string;
    externalState?: string;
    reviewState?: string;
    assigned?: string[];
    autoNotifyEnabled?: boolean;
    existingNotes?: string | null;
    failAfterGroupAssignment?: boolean;
    approveImmediately?: boolean;
    sparseBetaRelations?: boolean;
    env?: string;
  } = {},
) {
  const state = {
    externalState: options.externalState ?? "IN_BETA_TESTING",
    reviewState: options.reviewState,
    assigned: new Set(options.assigned ?? ["internal", "public"]),
    autoNotifyEnabled: options.autoNotifyEnabled ?? true,
    notes: options.existingNotes === undefined ? notes : options.existingNotes,
  };
  const writes: { method: string; path: string; body: unknown }[] = [];
  const fetchMock = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = new URL(String(input));
    const method = init?.method ?? "GET";
    if (url.origin !== "https://api.appstoreconnect.apple.com") throw new Error("Unexpected origin");
    const path = url.pathname;
    const detail = {
      type: "buildBetaDetails",
      id: "detail-46",
      attributes: {
        externalBuildState: state.externalState,
        internalBuildState: "IN_BETA_TESTING",
        autoNotifyEnabled: state.autoNotifyEnabled,
      },
    };
    const reviews = state.reviewState
      ? [{ type: "betaAppReviewSubmissions", id: "review-46", attributes: { betaReviewState: state.reviewState } }]
      : [];
    const groupResource = (id: string) => ({
      type: "betaGroups",
      id,
      attributes: {
        name: id,
        isInternalGroup: id === "internal",
        hasAccessToAllBuilds: false,
        publicLinkEnabled: id === "public",
      },
      relationships: { app: linkage("apps", options.groupAppId ?? config.appId) },
    });
    if (method === "GET") {
      if (path === `/v1/apps/${config.appId}`) {
        return Response.json({
          data: {
            type: "apps",
            id: config.appId,
            attributes: { name: "RichOS", bundleId: options.bundleId ?? BUNDLE, primaryLocale: "en-US" },
          },
        });
      }
      if (path === "/v1/betaGroups/public" || path === "/v1/betaGroups/internal") {
        NodeAssert.equal(url.searchParams.get("include"), "app");
        return Response.json({ data: groupResource(path.endsWith("public") ? "public" : "internal") });
      }
      if (path === "/v1/builds") {
        NodeAssert.equal(url.searchParams.get("filter[app]"), config.appId);
        NodeAssert.equal(url.searchParams.get("filter[version]"), "46");
        NodeAssert.equal(url.searchParams.get("filter[preReleaseVersion.version]"), VERSION);
        const build = {
          type: "builds",
          id: "build-46",
          attributes: {
            version: "46",
            processingState: options.processingState ?? "VALID",
            expired: false,
            buildAudienceType: "APP_STORE_ELIGIBLE",
          },
          relationships: {
            app: url.searchParams.get("include")?.split(",").includes("app")
              ? linkage("apps", options.buildAppId ?? config.appId)
              : { links: { related: "/v1/builds/build-46/app" } },
            preReleaseVersion: linkage("preReleaseVersions", "version-1"),
            buildBetaDetail: options.sparseBetaRelations ? {} : linkage("buildBetaDetails", "detail-46"),
            betaAppReviewSubmission: options.sparseBetaRelations
              ? {}
              : state.reviewState
                ? linkage("betaAppReviewSubmissions", "review-46")
                : { data: null },
          },
        };
        return Response.json({
          data: options.buildExists === false ? [] : [build],
          included: [
            { type: "preReleaseVersions", id: "version-1", attributes: { version: VERSION, platform: "IOS" } },
            ...(options.sparseBetaRelations ? [] : [detail, ...reviews]),
          ],
        });
      }
      if (path === "/v1/buildBetaDetails" || path === "/v1/betaAppReviewSubmissions") {
        NodeAssert.equal(url.searchParams.get("filter[build]"), "build-46");
        return Response.json({ data: path === "/v1/buildBetaDetails" ? [detail] : reviews });
      }
      if (path === "/v1/betaGroups") {
        NodeAssert.equal(url.searchParams.has("filter[app]"), false);
        NodeAssert.equal(url.searchParams.get("filter[builds]"), "build-46");
        return Response.json({ data: [...state.assigned].map(groupResource) });
      }
      if (path === "/v1/builds/build-46/betaBuildLocalizations") {
        return Response.json({
          data:
            state.notes === null
              ? []
              : [{ type: "betaBuildLocalizations", id: "notes-46", attributes: { locale: "en-US", whatsNew: state.notes } }],
        });
      }
    } else {
      const body: unknown = JSON.parse(String(init?.body));
      writes.push({ method, path, body });
      if (path === "/v1/betaBuildLocalizations" || path === "/v1/betaBuildLocalizations/notes-46") {
        state.notes = notes;
        return Response.json({ data: { type: "betaBuildLocalizations", id: "notes-46" } });
      }
      if (path === "/v1/buildBetaDetails/detail-46") {
        state.autoNotifyEnabled = true;
        return Response.json({ data: { type: "buildBetaDetails", id: "detail-46" } });
      }
      if (path === "/v1/betaGroups/public/relationships/builds" || path === "/v1/betaGroups/internal/relationships/builds") {
        state.assigned.add(path.includes("/public/") ? "public" : "internal");
        if (options.failAfterGroupAssignment) throw new Error("Lost response after write");
        return new Response(null, { status: 204 });
      }
      if (path === "/v1/betaAppReviewSubmissions") {
        state.externalState = options.approveImmediately ? "BETA_APPROVED" : "WAITING_FOR_BETA_REVIEW";
        state.reviewState = options.approveImmediately ? "APPROVED" : "WAITING_FOR_REVIEW";
        return Response.json({ data: { type: "betaAppReviewSubmissions", id: "review-46" } }, { status: 201 });
      }
      if (path === "/v1/buildBetaNotifications") {
        state.externalState = "IN_BETA_TESTING";
        return Response.json({ data: { type: "buildBetaNotifications", id: "notification-46" } }, { status: 201 });
      }
    }
    throw new Error(`Unexpected request: ${method} ${path}`);
  };
  const parsed = parseTestFlightEnv(options.env ?? envSource);
  return { client: createTestFlightClient(parsed.config, keys.privateKey, fetchMock), state, writes };
}

describe("App Store Connect authentication", () => {
  it("does not print a token echoed in an API error", async () => {
    let capturedToken = "";
    const client = createTestFlightClient(config, keys.privateKey, async (_input, init) => {
      capturedToken = new Headers(init?.headers).get("Authorization")?.slice(7) ?? "";
      return Response.json({ errors: [{ detail: `Rejected ${capturedToken}` }] }, { status: 401 });
    });
    await NodeAssert.rejects(client.status(selection), /Rejected \[redacted token\]/u);
    NodeAssert.notEqual(capturedToken, "");
  });

  it("parses a quoted env file and restores the downloaded PEM key", () => {
    const parsed = parseTestFlightEnv(envSource);
    NodeAssert.deepEqual(parsed.config, {
      keyId: "TESTKEY123",
      issuerId: "00000000-0000-0000-0000-000000000001",
      appId: "12345",
      bundleId: BUNDLE,
      publicGroupId: "public",
      internalGroupId: "internal",
    });
    NodeAssert.equal(
      NodeCrypto.createPublicKey(parsed.privateKey).export({ type: "spki", format: "pem" }),
      keys.publicKey.export({ type: "spki", format: "pem" }),
    );
  });

  it("does not export parsed env variables to the process", () => {
    const before = process.env.RICHOS_IOS_ENV_PARSE_TEST_SENTINEL;
    parseTestFlightEnv(`${envSource}RICHOS_IOS_ENV_PARSE_TEST_SENTINEL="local only"\n`);
    NodeAssert.equal(process.env.RICHOS_IOS_ENV_PARSE_TEST_SENTINEL, before);
  });

  it("requires the bundle identifier in the private file (the production one is the CEO's)", () => {
    NodeAssert.throws(() => parseTestFlightEnv(envSource.replace(`RICHOS_IOS_ASC_BUNDLE_ID=${BUNDLE}\n`, "")), /RICHOS_IOS_ASC_BUNDLE_ID/u);
    NodeAssert.throws(() => parseTestFlightEnv(envSource.replace(BUNDLE, "dev richos/../x")), /bundle identifier/u);
  });

  it("requires private permissions on the env file, outside any git working tree", async () => {
    const directory = await NodeFSP.mkdtemp(NodePath.join(NodeOS.tmpdir(), "richos-testflight-env-test-"));
    const path = NodePath.join(directory, "testflight.env");
    try {
      NodeAssert.equal(insideGitWorkTree(path), false, "the test's own temporary directory must not be in a work tree");
      await NodeFSP.writeFile(path, envSource, { mode: 0o600 });
      NodeAssert.deepEqual((await readTestFlightEnv(path)).config, config);
      await NodeFSP.chmod(path, 0o644);
      await NodeAssert.rejects(readTestFlightEnv(path), /mode 600/u);
      // A credentials file in a checkout is refused before it is read, whatever its mode.
      await NodeFSP.mkdir(NodePath.join(directory, "checkout", ".git"), { recursive: true });
      const inRepo = NodePath.join(directory, "checkout", "config", "testflight.env");
      await NodeFSP.mkdir(NodePath.dirname(inRepo), { recursive: true });
      await NodeFSP.writeFile(inRepo, envSource, { mode: 0o600 });
      NodeAssert.equal(insideGitWorkTree(inRepo), true);
      await NodeAssert.rejects(readTestFlightEnv(inRepo), /inside a git working tree/u);
    } finally {
      await NodeFSP.rm(directory, { recursive: true, force: true });
    }
  });

  for (const fail of [false, true]) {
    it(`removes the temporary Xcode key after ${fail ? "failure" : "success"}`, async () => {
      let temporaryPath: string | undefined;
      const operation = withTemporaryPrivateKey(keys.privateKey, async (path) => {
        temporaryPath = path;
        NodeAssert.equal((await NodeFSP.stat(path)).mode & 0o777, 0o600);
        NodeAssert.equal((await NodeFSP.stat(NodePath.dirname(path))).mode & 0o777, 0o700);
        const savedKey = NodeCrypto.createPrivateKey(await NodeFSP.readFile(path));
        NodeAssert.equal(
          NodeCrypto.createPublicKey(savedKey).export({ type: "spki", format: "pem" }),
          keys.publicKey.export({ type: "spki", format: "pem" }),
        );
        if (fail) throw new Error("Upload failed");
      });
      if (fail) await NodeAssert.rejects(operation, /Upload failed/u);
      else await operation;
      if (!temporaryPath) throw new Error("The upload callback did not run");
      await NodeAssert.rejects(NodeFSP.stat(NodePath.dirname(temporaryPath)), { code: "ENOENT" });
    });
  }

  it("signs a ten-minute ES256 token with the API audience and P1363 signature", () => {
    const token = makeAppStoreToken(config, keys.privateKey, 1_000);
    const [header, payload, signature] = token.split(".");
    if (!header || !payload || !signature) throw new Error("Invalid token");
    NodeAssert.deepEqual(JSON.parse(Buffer.from(header, "base64url").toString()), { alg: "ES256", kid: config.keyId, typ: "JWT" });
    NodeAssert.deepEqual(JSON.parse(Buffer.from(payload, "base64url").toString()), {
      iss: config.issuerId,
      iat: 1_000,
      exp: 1_600,
      aud: "appstoreconnect-v1",
    });
    NodeAssert.equal(Buffer.from(signature, "base64url").length, 64);
    NodeAssert.equal(
      NodeCrypto.verify(
        "sha256",
        Buffer.from(`${header}.${payload}`),
        { key: keys.publicKey, dsaEncoding: "ieee-p1363" },
        Buffer.from(signature, "base64url"),
      ),
      true,
    );
  });

  it("rejects a key that cannot sign ES256", () => {
    const wrongKey = NodeCrypto.generateKeyPairSync("ed25519");
    NodeAssert.throws(() => makeAppStoreToken(config, wrongKey.privateKey), /P-256 private key/u);
  });
});

describe("TestFlight publication", () => {
  for (const options of [{ bundleId: `${BUNDLE}.dev` }, { groupAppId: "other-app" }, { buildAppId: "other-app" }]) {
    it(`refuses wrong-app targets before any write: ${JSON.stringify(options)}`, async () => {
      const server = mockServer(options);
      await NodeAssert.rejects(server.client.publish(selection, notes), /Refusing|different app/u);
      NodeAssert.deepEqual(server.writes, []);
    });
  }

  it("does not duplicate group assignment, review, or notifications for a testing build", async () => {
    const server = mockServer();
    const result = await server.client.publish(selection, notes);
    NodeAssert.equal(result.publicTesting, true);
    NodeAssert.deepEqual(server.writes, []);
  });

  it("sets notes, assigns both groups, and submits once without claiming review is complete", async () => {
    const server = mockServer({
      externalState: "READY_FOR_BETA_SUBMISSION",
      assigned: [],
      autoNotifyEnabled: false,
      existingNotes: null,
    });
    const result = await server.client.publish(selection, notes);
    NodeAssert.equal(result.publicTesting, false);
    NodeAssert.equal(result.externalState, "WAITING_FOR_BETA_REVIEW");
    NodeAssert.deepEqual(
      server.writes.map(({ method, path }) => `${method} ${path}`),
      [
        "POST /v1/betaBuildLocalizations",
        "PATCH /v1/buildBetaDetails/detail-46",
        "POST /v1/betaGroups/internal/relationships/builds",
        "POST /v1/betaGroups/public/relationships/builds",
        "POST /v1/betaAppReviewSubmissions",
      ],
    );
    NodeAssert.deepEqual(server.writes.at(-1)?.body, {
      data: { type: "betaAppReviewSubmissions", relationships: { build: linkage("builds", "build-46") } },
    });
    await server.client.publish(selection, notes);
    NodeAssert.equal(server.writes.length, 5);
  });

  it("notifies an approved build once and rereads the resulting testing state", async () => {
    const server = mockServer({ externalState: "BETA_APPROVED", reviewState: "APPROVED" });
    const result = await server.client.publish(selection, notes);
    NodeAssert.equal(result.publicTesting, true);
    NodeAssert.deepEqual(server.writes.map((item) => item.path), ["/v1/buildBetaNotifications"]);
    await server.client.publish(selection, notes);
    NodeAssert.equal(server.writes.length, 1);
  });

  it("leaves automatic notification alone when a new review immediately becomes approved", async () => {
    const server = mockServer({ externalState: "READY_FOR_BETA_SUBMISSION", approveImmediately: true });
    const result = await server.client.publish(selection, notes);
    NodeAssert.equal(result.externalState, "BETA_APPROVED");
    NodeAssert.equal(result.publicTesting, false);
    NodeAssert.deepEqual(server.writes.map((item) => item.path), ["/v1/betaAppReviewSubmissions"]);
  });

  it("checks missing review linkage before deciding whether a submission exists", async () => {
    const server = mockServer({
      externalState: "READY_FOR_BETA_SUBMISSION",
      reviewState: "WAITING_FOR_REVIEW",
      sparseBetaRelations: true,
    });
    const result = await server.client.publish(selection, notes);
    NodeAssert.equal(result.reviewState, "WAITING_FOR_REVIEW");
    NodeAssert.deepEqual(server.writes, []);
  });

  for (const options of [
    { processingState: "PROCESSING" },
    { externalState: "MISSING_EXPORT_COMPLIANCE" },
    { externalState: "BETA_REJECTED", reviewState: "REJECTED" },
    { buildExists: false },
  ]) {
    it(`fails before writes for a build that is not ready: ${JSON.stringify(options)}`, async () => {
      const server = mockServer(options);
      await NodeAssert.rejects(server.client.publish(selection, notes));
      NodeAssert.deepEqual(server.writes, []);
    });
  }

  it("does not retry a write when the response is lost", async () => {
    const server = mockServer({ assigned: ["public"], failAfterGroupAssignment: true });
    await NodeAssert.rejects(server.client.publish(selection, notes), /The write was not retried/u);
    NodeAssert.equal(server.writes.length, 1);
    NodeAssert.equal(server.state.assigned.has("internal"), true);
    await server.client.publish(selection, notes);
    NodeAssert.equal(server.writes.length, 1);
  });

  it("refuses another upload of a build that Apple already has", async () => {
    const server = mockServer();
    await NodeAssert.rejects(server.client.verifyUpload(selection), /already exists/u);
    NodeAssert.deepEqual(server.writes, []);
  });

  it("verifies app and groups before allowing a new upload", async () => {
    const server = mockServer({ buildExists: false });
    await server.client.verifyUpload(selection);
    NodeAssert.deepEqual(server.writes, []);
  });
});

describe("internal testing only (RichOS's first target, no public group configured)", () => {
  it("assigns the internal group and never submits for beta review or touches a public group", async () => {
    const server = mockServer({
      env: internalOnlySource,
      externalState: "READY_FOR_BETA_SUBMISSION",
      assigned: [],
      autoNotifyEnabled: false,
      existingNotes: null,
    });
    const result = await server.client.publish(selection, notes);
    NodeAssert.deepEqual(
      server.writes.map(({ method, path }) => `${method} ${path}`),
      ["POST /v1/betaBuildLocalizations", "PATCH /v1/buildBetaDetails/detail-46", "POST /v1/betaGroups/internal/relationships/builds"],
    );
    NodeAssert.equal(result.internalTesting, true);
    NodeAssert.deepEqual(result.groups.map((group) => group.id), ["internal"]);
    await server.client.publish(selection, notes);
    NodeAssert.equal(server.writes.length, 3, "a rerun writes nothing");
  });

  it("still refuses a build that is not processed", async () => {
    const server = mockServer({ env: internalOnlySource, processingState: "PROCESSING" });
    await NodeAssert.rejects(server.client.publish(selection, notes), /processing is PROCESSING/u);
    NodeAssert.deepEqual(server.writes, []);
  });
});

describe("release command input", () => {
  const info = { CFBundleIdentifier: BUNDLE, DTPlatformName: "iphoneos", CFBundleVersion: "46", CFBundleShortVersionString: VERSION };
  const exportOptions = { method: "app-store-connect", destination: "upload", manageAppVersionAndBuildNumber: false };

  it("reads an exact Release build from archive metadata", () => {
    NodeAssert.deepEqual(validateUploadMetadata(info, exportOptions, BUNDLE), selection);
  });

  for (const metadata of [{ ...info, CFBundleIdentifier: `${BUNDLE}.dev` }, { ...info, DTPlatformName: "iphonesimulator" }]) {
    it(`rejects a dev or simulator archive: ${JSON.stringify(metadata)}`, () => {
      NodeAssert.throws(() => validateUploadMetadata(metadata, exportOptions, BUNDLE), /Release RichOS app/u);
    });
  }

  for (const options of [{ ...exportOptions, destination: "export" }, { ...exportOptions, manageAppVersionAndBuildNumber: true }]) {
    it(`rejects export options that would change the release: ${JSON.stringify(options)}`, () => {
      NodeAssert.throws(() => validateUploadMetadata(info, options, BUNDLE));
    });
  }

  it("the committed Release/ExportOptions.plist passes the upload's own checks", () => {
    const plist = NodePath.join(import.meta.dirname, "ExportOptions.plist");
    const json = NodeChildProcess.execFileSync("/usr/bin/plutil", ["-convert", "json", "-o", "-", plist], { encoding: "utf8" });
    NodeAssert.deepEqual(validateUploadMetadata(info, JSON.parse(json), BUNDLE), selection);
  });

  it("accepts an internal-only export (RichOS's first target)", () => {
    NodeAssert.deepEqual(validateUploadMetadata(info, { ...exportOptions, testFlightInternalTestingOnly: true }, BUNDLE), selection);
  });

  it("requires explicit release notes for publication", () => {
    NodeAssert.throws(() => parseTestFlightArgs(["publish", "--build", "46", "--version", VERSION]), /--notes-file/u);
    const parsed = parseTestFlightArgs(["status", "--build", "46", "--version", VERSION, "--env-file", "/tmp/testflight.env"]);
    NodeAssert.equal(parsed.command, "status");
    NodeAssert.equal((parsed as { envFile: string }).envFile, "/tmp/testflight.env");
  });

  it("requires supplied export options and reads upload versions only from the archive", () => {
    const parsed = parseTestFlightArgs(["upload", "--archive", "/tmp/Test.xcarchive", "--export-options", "/tmp/ExportOptions.plist"]);
    NodeAssert.equal(parsed.command, "upload");
    NodeAssert.throws(
      () => parseTestFlightArgs(["upload", "--archive", "/tmp/Test.xcarchive", "--export-options", "/tmp/ExportOptions.plist", "--build", "47"]),
      /reads the build and version from the archive/u,
    );
  });

  it("never takes credentials from the command line", () => {
    NodeAssert.throws(() => parseTestFlightArgs(["status", "--build", "46", "--version", VERSION, "--key", "x"]));
  });
});
