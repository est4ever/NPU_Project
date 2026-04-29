module.exports = {
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        page: "#05070d",
        panel: "#0a1120",
        line: "#1a2a44",
        accent: "#20d7ff"
      },
      boxShadow: {
        glow: "0 0 0 1px rgba(32,215,255,0.3), 0 0 28px rgba(32,215,255,0.12)"
      }
    }
  },
  plugins: []
};
