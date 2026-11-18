using System.Text.Json;

namespace LogRouter;

public sealed record Filter
{
    public Filter[]? All { get; init; }
    public Filter[]? Any { get; init; }
    public Filter? Not { get; init; }
    public string? Field { get; init; }
    public string? Op { get; init; }
    public JsonElement Value { get; init; }
    public bool IgnoreCase { get; init; }

    public void Validate()
    {
        var count = 0;
        ValidateNode(0, ref count);
    }

    private void ValidateNode(int depth, ref int count)
    {
        RouterConfiguration.Require(depth <= 16 && ++count <= 256, "Filter exceeds depth/node limit.");
        var branches = (All is not null ? 1 : 0) + (Any is not null ? 1 : 0)
            + (Not is not null ? 1 : 0) + (Field is not null ? 1 : 0);
        RouterConfiguration.Require(branches == 1, "A filter requires exactly one of all/any/not/field.");
        if (Field is null)
        {
            RouterConfiguration.Require(Op is null && Value.ValueKind == JsonValueKind.Undefined && !IgnoreCase,
                "Group filters cannot contain leaf properties.");
            var children = All ?? Any ?? [Not!];
            RouterConfiguration.Require(children.Length > 0, "Filter groups cannot be empty.");
            foreach (var child in children)
            {
                RouterConfiguration.Require(child is not null, "Filter children cannot be null.");
                child!.ValidateNode(depth + 1, ref count);
            }
            return;
        }

        RouterConfiguration.Require(Field.Split('.').All(x => !string.IsNullOrWhiteSpace(x)), "Invalid filter field path.");
        RouterConfiguration.Require(Op is "eq" or "ne" or "gt" or "ge" or "lt" or "le"
            or "in" or "contains" or "startsWith" or "endsWith" or "exists", "Unknown filter operator.");
        if (Op == "exists")
            RouterConfiguration.Require(Value.ValueKind == JsonValueKind.Undefined && !IgnoreCase,
                "exists has no value or ignoreCase option.");
        else
            RouterConfiguration.Require(Value.ValueKind != JsonValueKind.Undefined, "Filter value is required.");
        if (Op == "in")
            RouterConfiguration.Require(Value.ValueKind == JsonValueKind.Array && Value.GetArrayLength() > 0,
                "in requires a nonempty array.");
        if (Op is "gt" or "ge" or "lt" or "le")
            RouterConfiguration.Require(Value.ValueKind == JsonValueKind.Number && Value.TryGetDecimal(out _) && !IgnoreCase,
                "Ordering requires a decimal number and does not support ignoreCase.");
        if (Op is "contains" or "startsWith" or "endsWith")
            RouterConfiguration.Require(Value.ValueKind == JsonValueKind.String, "String operators require a string.");
        if (IgnoreCase)
            RouterConfiguration.Require(Value.ValueKind == JsonValueKind.String
                || (Op == "in" && Value.EnumerateArray().All(x => x.ValueKind == JsonValueKind.String)),
                "ignoreCase requires string values.");
    }

    public bool Matches(JsonElement record)
    {
        if (All is not null) return All.All(x => x.Matches(record));
        if (Any is not null) return Any.Any(x => x.Matches(record));
        if (Not is not null) return !Not.Matches(record);
        var found = TryRead(record, Field!, out var actual);
        if (Op == "exists") return found;
        if (!found) return false;
        var comparison = IgnoreCase ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        bool Equal(JsonElement other) =>
            actual.ValueKind == JsonValueKind.String && other.ValueKind == JsonValueKind.String
                ? string.Equals(actual.GetString(), other.GetString(), comparison)
                : JsonElement.DeepEquals(actual, other);
        return Op switch
        {
            "eq" => Equal(Value),
            "ne" => !Equal(Value),
            "in" => Value.EnumerateArray().Any(Equal),
            "contains" => actual.ValueKind == JsonValueKind.String && actual.GetString()!.Contains(Value.GetString()!, comparison),
            "startsWith" => actual.ValueKind == JsonValueKind.String && actual.GetString()!.StartsWith(Value.GetString()!, comparison),
            "endsWith" => actual.ValueKind == JsonValueKind.String && actual.GetString()!.EndsWith(Value.GetString()!, comparison),
            "gt" or "ge" or "lt" or "le" => CompareNumber(actual),
            _ => throw new InvalidOperationException("Filter was not validated.")
        };
    }

    private bool CompareNumber(JsonElement actual)
    {
        if (actual.ValueKind != JsonValueKind.Number || !actual.TryGetDecimal(out var left)) return false;
        var right = Value.GetDecimal();
        return Op switch { "gt" => left > right, "ge" => left >= right, "lt" => left < right, "le" => left <= right, _ => false };
    }

    public static bool TryRead(JsonElement record, string path, out JsonElement value)
    {
        value = record;
        foreach (var part in path.Split('.'))
        {
            if (value.ValueKind != JsonValueKind.Object || !value.TryGetProperty(part, out value))
            {
                value = default;
                return false;
            }
        }
        return true;
    }
}
