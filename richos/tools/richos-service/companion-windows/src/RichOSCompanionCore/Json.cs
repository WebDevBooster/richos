using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace RichOSCompanionCore
{
    /// <summary>
    /// A tiny insertion-ordered JSON value model — the C# peer of the macOS companion's
    /// <c>JSON.swift</c>.
    ///
    /// The frozen contract (P1 <c>tools/richos-service/README.md</c>) is consumed by
    /// <c>JSON.parse</c>, so field ORDER is not functionally load-bearing — but explicit
    /// <c>null</c> vs <em>omitted</em> IS (the extension's <c>session.json</c> carries
    /// <c>endedAt: null</c>, <c>pipeline.model: null</c>, etc., and the pipeline's
    /// <c>upgradeRecord</c> only fills a block when it is ABSENT, so we must emit the full v2 shape
    /// with real nulls, not omit them). A generic serializer that drops nulls would be wrong here —
    /// this model gives byte-for-shape control and preserves a human-readable insertion order.
    /// </summary>
    public sealed class Json
    {
        private enum Kind { String, Int, Double, Bool, Null, Array, Object }

        private readonly Kind _kind;
        private readonly string? _string;
        private readonly long _int;
        private readonly double _double;
        private readonly bool _bool;
        private readonly List<Json>? _array;
        private readonly List<KeyValuePair<string, Json>>? _object;

        private Json(Kind kind, string? s = null, long i = 0, double d = 0, bool b = false,
                     List<Json>? array = null, List<KeyValuePair<string, Json>>? obj = null)
        {
            _kind = kind;
            _string = s;
            _int = i;
            _double = d;
            _bool = b;
            _array = array;
            _object = obj;
        }

        public static Json Str(string s) => new Json(Kind.String, s: s);
        public static Json Int(long i) => new Json(Kind.Int, i: i);
        public static Json Dbl(double d) => new Json(Kind.Double, d: d);
        public static Json Bool(bool b) => new Json(Kind.Bool, b: b);
        public static readonly Json Null = new Json(Kind.Null);
        public static Json Arr(IEnumerable<Json> items) => new Json(Kind.Array, array: new List<Json>(items));
        public static Json Arr(params Json[] items) => new Json(Kind.Array, array: new List<Json>(items));

        /// <summary>Ordered object: (key, value) pairs serialized in insertion order.</summary>
        public static Json Obj(params (string Key, Json Value)[] pairs)
        {
            var list = new List<KeyValuePair<string, Json>>(pairs.Length);
            foreach (var (k, v) in pairs) list.Add(new KeyValuePair<string, Json>(k, v));
            return new Json(Kind.Object, obj: list);
        }

        public static Json Obj(IEnumerable<KeyValuePair<string, Json>> pairs)
            => new Json(Kind.Object, obj: new List<KeyValuePair<string, Json>>(pairs));

        /// <summary>Optional string helper: null =&gt; JSON null, else JSON string.</summary>
        public static Json StrOrNull(string? s) => s is null ? Null : Str(s);

        /// <summary>Serialize with the same 2-space indentation the pipeline uses.</summary>
        public string Serialized(int indent = 0)
        {
            var pad = new string(' ', indent * 2);
            var pad1 = new string(' ', (indent + 1) * 2);
            switch (_kind)
            {
                case Kind.String: return EncodeString(_string!);
                case Kind.Int: return _int.ToString(CultureInfo.InvariantCulture);
                case Kind.Double: return EncodeDouble(_double);
                case Kind.Bool: return _bool ? "true" : "false";
                case Kind.Null: return "null";
                case Kind.Array:
                    if (_array!.Count == 0) return "[]";
                    {
                        var parts = new List<string>(_array.Count);
                        foreach (var item in _array) parts.Add(pad1 + item.Serialized(indent + 1));
                        return "[\n" + string.Join(",\n", parts) + "\n" + pad + "]";
                    }
                case Kind.Object:
                    if (_object!.Count == 0) return "{}";
                    {
                        var parts = new List<string>(_object.Count);
                        foreach (var kv in _object)
                            parts.Add(pad1 + EncodeString(kv.Key) + ": " + kv.Value.Serialized(indent + 1));
                        return "{\n" + string.Join(",\n", parts) + "\n" + pad + "}";
                    }
                default: return "null";
            }
        }

        /// <summary>Pretty document bytes, trailing newline (matches macOS <c>JSON.data()</c>).</summary>
        public byte[] Data() => Encoding.UTF8.GetBytes(Serialized() + "\n");

        /// <summary>Compact single-line serialization (for ndjson rows).</summary>
        public string Compact()
        {
            switch (_kind)
            {
                case Kind.String: return EncodeString(_string!);
                case Kind.Int: return _int.ToString(CultureInfo.InvariantCulture);
                case Kind.Double: return EncodeDouble(_double);
                case Kind.Bool: return _bool ? "true" : "false";
                case Kind.Null: return "null";
                case Kind.Array:
                    {
                        var parts = new List<string>(_array!.Count);
                        foreach (var item in _array) parts.Add(item.Compact());
                        return "[" + string.Join(",", parts) + "]";
                    }
                case Kind.Object:
                    {
                        var parts = new List<string>(_object!.Count);
                        foreach (var kv in _object) parts.Add(EncodeString(kv.Key) + ":" + kv.Value.Compact());
                        return "{" + string.Join(",", parts) + "}";
                    }
                default: return "null";
            }
        }

        // Integer-valued doubles print without a decimal point (matches the macOS/JS serializer, so a
        // whole-number sampleRate/level never renders as "48000.0").
        private static string EncodeDouble(double d)
        {
            if (d == Math.Round(d) && Math.Abs(d) < 1e15)
                return ((long)d).ToString(CultureInfo.InvariantCulture);
            return d.ToString("R", CultureInfo.InvariantCulture);
        }

        internal static string EncodeString(string s)
        {
            var sb = new StringBuilder(s.Length + 2);
            sb.Append('"');
            foreach (var ch in s)
            {
                switch (ch)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default:
                        if (ch < 0x20) sb.Append("\\u").Append(((int)ch).ToString("x4", CultureInfo.InvariantCulture));
                        else sb.Append(ch);
                        break;
                }
            }
            sb.Append('"');
            return sb.ToString();
        }
    }
}
