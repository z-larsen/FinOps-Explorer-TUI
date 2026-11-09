// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
//
// FORECAST.AGGREGATOR.CS
// Row-level reduction for export partitions.
//
// Reads every CSV row with the same TextFieldParser the PowerShell path uses
// and sums rows that share the same raw values into one tuple. It never
// classifies charges; PowerShell applies the forecast rules to each distinct
// tuple, so both paths share one set of rules. Rows are summed, never
// deduplicated, and amounts are parsed as invariant-culture decimals.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.VisualBasic.FileIO;

namespace FinOpsForecast.V1
{
    public sealed class AggregatorOptions
    {
        public int Width;
        public int Date = -1, Subscription = -1, Name = -1, ResourceGroup = -1, Tags = -1, Cost = -1, Currency = -1;
        public int Charge = -1, ChargeClass = -1, PublisherType = -1, PublisherName = -1, Pricing = -1, PricingCategory = -1;
        public int UnitPrice = -1, Quantity = -1, Contracted = -1, Profile = -1, Account = -1, Agreement = -1, Frequency = -1;
        public int[] CommitmentColumns = new int[0];
        public string TagKey;
        public string[] PurchaseCharges = new string[0];
        public long MaxRows = 200000000;
    }

    public sealed class RawTuple
    {
        public string[] Values;
        public decimal Cost;
        public long Rows;
        public decimal PositiveCost;
        public long PositiveRows;
        public decimal OnDemand;
    }

    public sealed class PartAggregate
    {
        public long Rows;
        public long ShapeErrors;
        public long CostErrors;
        public Dictionary<string, RawTuple> Tuples = new Dictionary<string, RawTuple>(StringComparer.Ordinal);
        public Dictionary<string, string> SubscriptionNames = new Dictionary<string, string>(StringComparer.Ordinal);
    }

    public static class CsvAggregator
    {
        private const NumberStyles AmountStyle = NumberStyles.Float;

        public static PartAggregate Aggregate(TextFieldParser parser, AggregatorOptions options)
        {
            var result = new PartAggregate();
            var purchase = new HashSet<string>(options.PurchaseCharges ?? new string[0], StringComparer.OrdinalIgnoreCase);
            Regex tagPattern = null;
            if (!string.IsNullOrEmpty(options.TagKey))
            {
                tagPattern = new Regex("\"" + Regex.Escape(options.TagKey) + "\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
            }
            var tagMemo = new Dictionary<string, string>(StringComparer.Ordinal);
            var keyBuilder = new StringBuilder(256);
            var culture = CultureInfo.InvariantCulture;

            while (!parser.EndOfData)
            {
                string[] f = parser.ReadFields();
                if (f == null || (f.Length == 1 && f[0].Length == 0)) { continue; }
                result.Rows++;
                if (result.Rows > options.MaxRows) { throw new InvalidOperationException("The partition exceeds the supported row count."); }
                if (f.Length != options.Width) { result.ShapeErrors++; continue; }
                decimal cost;
                if (!decimal.TryParse(f[options.Cost], AmountStyle, culture, out cost)) { result.CostErrors++; continue; }

                string charge = Field(f, options.Charge);
                bool isPurchase = purchase.Contains(charge.Trim());
                string tag = string.Empty;
                if (tagPattern != null && options.Tags >= 0)
                {
                    string rawTags = f[options.Tags];
                    if (!tagMemo.TryGetValue(rawTags, out tag))
                    {
                        tag = ExtractTag(rawTags, tagPattern);
                        tagMemo[rawTags] = tag;
                    }
                }
                string commitment = string.Empty;
                string frequency = string.Empty;
                if (isPurchase)
                {
                    foreach (int column in options.CommitmentColumns)
                    {
                        string value = f[column].Trim();
                        if (value.Length > 0) { commitment = value.ToLowerInvariant(); break; }
                    }
                    frequency = Field(f, options.Frequency).Trim();
                }

                string[] values = new string[]
                {
                    Field(f, options.Date), Field(f, options.Subscription), Field(f, options.ResourceGroup).Trim().ToLowerInvariant(), tag,
                    charge, Field(f, options.ChargeClass), Field(f, options.PublisherType), Field(f, options.PublisherName),
                    Field(f, options.Pricing), Field(f, options.PricingCategory), Field(f, options.Agreement), Field(f, options.Account),
                    Field(f, options.Profile).Trim().ToLowerInvariant(), commitment, frequency, Field(f, options.Currency)
                };
                keyBuilder.Clear();
                for (int i = 0; i < values.Length; i++)
                {
                    if (i > 0) { keyBuilder.Append('\u001f'); }
                    keyBuilder.Append(values[i]);
                }
                string key = keyBuilder.ToString();
                RawTuple tuple;
                if (!result.Tuples.TryGetValue(key, out tuple))
                {
                    tuple = new RawTuple { Values = values };
                    result.Tuples[key] = tuple;
                }
                tuple.Cost += cost;
                tuple.Rows++;
                if (cost > 0m) { tuple.PositiveCost += cost; tuple.PositiveRows++; }

                decimal onDemand;
                if (options.Contracted >= 0)
                {
                    if (decimal.TryParse(f[options.Contracted], AmountStyle, culture, out onDemand)) { tuple.OnDemand += onDemand; }
                }
                else if (options.UnitPrice >= 0 && options.Quantity >= 0)
                {
                    decimal unit, quantity;
                    if (decimal.TryParse(f[options.UnitPrice], AmountStyle, culture, out unit) && decimal.TryParse(f[options.Quantity], AmountStyle, culture, out quantity)) { tuple.OnDemand += unit * quantity; }
                }

                if (options.Name >= 0 && options.Subscription >= 0)
                {
                    string subscription = f[options.Subscription];
                    string name = f[options.Name].Trim();
                    if (subscription.Trim().Length > 0 && name.Length > 0) { result.SubscriptionNames[subscription + "\u001f" + f[options.Date]] = name; }
                }
            }
            return result;
        }

        private static string Field(string[] fields, int index)
        {
            return index >= 0 ? fields[index] : string.Empty;
        }

        private static string ExtractTag(string tags, Regex pattern)
        {
            if (string.IsNullOrWhiteSpace(tags)) { return string.Empty; }
            Match match = pattern.Match(tags);
            if (!match.Success) { return string.Empty; }
            string value = match.Groups[1].Value;
            if (value.IndexOf('\\') >= 0) { value = UnescapeJson(value); }
            return value.Trim();
        }

        private static string UnescapeJson(string value)
        {
            var builder = new StringBuilder(value.Length);
            for (int i = 0; i < value.Length; i++)
            {
                char c = value[i];
                if (c != '\\' || i + 1 >= value.Length) { builder.Append(c); continue; }
                char next = value[++i];
                switch (next)
                {
                    case '"': builder.Append('"'); break;
                    case '\\': builder.Append('\\'); break;
                    case '/': builder.Append('/'); break;
                    case 'b': builder.Append('\b'); break;
                    case 'f': builder.Append('\f'); break;
                    case 'n': builder.Append('\n'); break;
                    case 'r': builder.Append('\r'); break;
                    case 't': builder.Append('\t'); break;
                    case 'u':
                        int code;
                        if (i + 4 < value.Length && int.TryParse(value.Substring(i + 1, 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out code))
                        {
                            builder.Append((char)code);
                            i += 4;
                        }
                        else { builder.Append("\\u"); }
                        break;
                    default: builder.Append('\\').Append(next); break;
                }
            }
            return builder.ToString();
        }
    }
}
