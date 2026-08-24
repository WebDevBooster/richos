using System.Text.Json;
using RichOSCompanionCore;
using Xunit;

namespace RichOSCompanionCore.Tests
{
    /// <summary>
    /// The Windows companion parses the SHARED authority's coordination answers (architecture §5.4). The
    /// decision logic lives once in the Node service; these tests prove the companion reads its
    /// verdicts faithfully + builds the correct promotion-ownership block — the seam that makes the
    /// system generic over companion type. Peer of the macOS companion's <c>CoordinationTests.swift</c>.
    /// </summary>
    public class CoordinationTests
    {
        [Fact]
        public void ParsesStandDownClaim()
        {
            const string json = @"{ ""request"": {""surface"":""desktop-companion-windows""},
              ""decision"": ""stand-down"",
              ""reason"": ""chrome-extension already owns this call"",
              ""conflictSessionId"": ""ext-1"",
              ""excludeProcessHint"": ""msedge"" }";
            var d = Coordination.ParseClaimResult(json);
            Assert.Equal(Coordination.ClaimKind.StandDown, d.Decision);
            Assert.Equal("ext-1", d.ConflictSessionId);
            Assert.Equal("msedge", d.ExcludeProcessHint);
        }

        [Fact]
        public void ParsesOwnClaimWithSupersede()
        {
            const string json = @"{ ""decision"": ""own"", ""reason"": ""richer surface supersedes"", ""supersede"": [""win-4""] }";
            var d = Coordination.ParseClaimResult(json);
            Assert.Equal(Coordination.ClaimKind.Own, d.Decision);
            Assert.Single(d.Supersede);
            Assert.Equal("win-4", d.Supersede[0]);
            Assert.Null(d.ConflictSessionId);
        }

        [Fact]
        public void MalformedClaimThrows()
        {
            Assert.Throws<Coordination.CoordException>(() => Coordination.ParseClaimResult("{ \"nope\": true }"));
        }

        [Fact]
        public void ParsesFailoverCandidates()
        {
            const string json = @"{ ""zone"": ""/tmp/z"",
              ""candidates"": [
                { ""sessionId"": ""ext-dead"", ""surface"": ""chrome-extension"", ""captureKind"": ""browser-tab"",
                  ""processHint"": ""msedge"", ""reason"": ""owner interrupted"" }
              ] }";
            var c = Coordination.ParseFailoverCandidates(json);
            Assert.Single(c);
            Assert.Equal("ext-dead", c[0].SessionId);
            Assert.Equal("chrome-extension", c[0].Surface);
            Assert.Equal("msedge", c[0].ProcessHint);
        }

        [Fact]
        public void PromotionOwnershipBlockMatchesTheContract()
        {
            var json = Coordination.PromotionOwnership("ext-dead", "msedge");
            var o = JsonDocument.Parse(json.Serialized()).RootElement;
            Assert.Equal("desktop-companion-windows", o.GetProperty("ownerSurface").GetString());
            Assert.Equal("ext-dead", o.GetProperty("supersedes").GetString());
            Assert.Equal("msedge", o.GetProperty("processHint").GetString());
        }
    }
}
