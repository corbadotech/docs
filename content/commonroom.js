(function () {
    if (typeof window === "undefined") return;
    if (typeof window.signals !== "undefined") return;
    var script = document.createElement("script");
    script.src =
        "https://cdn.cr-relay.com/v1/site/beff16ac-1c7c-4b80-b124-f64caf351663/signals.js";
    script.async = true;
    window.signals = Object.assign(
        [],
        { _opts: { apiHost: "https://api.cr-relay.com" } },
        ["page", "identify", "form"].reduce(function (acc, method) {
            acc[method] = function () {
                signals.push([method, arguments]);
                return signals;
            };
            return acc;
        }, {})
    );
    document.head.appendChild(script);
})();
