using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Xunit;

namespace FlashSale.OrderService.Tests;

/// <summary>
/// Week 11 milestone, Task A (TP-P06): every published message must carry the
/// AMQP <c>timestamp</c> property so the broker's <c>head_message_timestamp</c>
/// can report the oldest-message age. This is a source-scan guard: it walks
/// <c>src/</c> and fails if any <c>new BasicProperties</c> object initializer
/// lacks a <c>Timestamp = new AmqpTimestamp(…)</c> setter, so a future
/// publisher cannot forget it.
/// </summary>
public class MessageTimestampSourceScanTests
{
    private const string Marker = "new BasicProperties";
    private const string RequiredSetter = "Timestamp = new AmqpTimestamp";

    [Fact]
    public void Every_BasicProperties_initializer_in_src_sets_a_Timestamp()
    {
        var srcRoot = FindSrcRoot();
        Assert.True(srcRoot is not null, "Could not locate src/ from " + AppContext.BaseDirectory);

        var files = Directory.EnumerateFiles(srcRoot!, "*.cs", SearchOption.AllDirectories).ToList();
        var sites = new List<(string File, int Offset)>();
        foreach (var file in files)
        {
            var text = File.ReadAllText(file);
            var index = 0;
            while ((index = text.IndexOf(Marker, index, StringComparison.Ordinal)) >= 0)
            {
                sites.Add((file, index));
                index += Marker.Length;
            }
        }

        Assert.True(sites.Count > 0, "Found no `new BasicProperties` in src/; the guard is vacuous.");

        var failures = new List<string>();
        foreach (var site in sites)
        {
            var text = File.ReadAllText(site.File);
            var initializer = ObjectInitializer(text, site.Offset + Marker.Length);
            if (!initializer.Contains(RequiredSetter, StringComparison.Ordinal))
            {
                failures.Add(site.File);
            }
        }

        Assert.True(
            failures.Count == 0,
            "These files contain a `new BasicProperties` without `Timestamp = new AmqpTimestamp`: " +
            string.Join(", ", failures.Distinct()));
    }

    private static string? FindSrcRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            if (Directory.Exists(Path.Combine(dir.FullName, "src")) &&
                Directory.Exists(Path.Combine(dir.FullName, "tests")))
            {
                return Path.Combine(dir.FullName, "src");
            }
            dir = dir.Parent;
        }
        return null;
    }

    /// <summary>
    /// Returns the object-initializer block that begins right after
    /// <c>new BasicProperties</c>, tracking brace depth so a nested initializer
    /// (for example <c>Headers = new Dictionary&lt;string, object?&gt; { … }</c>)
    /// does not end the block early.
    /// </summary>
    private static string ObjectInitializer(string text, int start)
    {
        var open = text.IndexOf('{', start);
        if (open < 0)
        {
            return string.Empty;
        }

        var depth = 0;
        for (var i = open; i < text.Length; i++)
        {
            switch (text[i])
            {
                case '{':
                    depth++;
                    break;
                case '}':
                    depth--;
                    if (depth == 0)
                    {
                        return text.Substring(open, i - open + 1);
                    }
                    break;
            }
        }
        return text.Substring(open);
    }
}
