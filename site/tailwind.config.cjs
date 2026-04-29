module.exports = {
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        page: "#0a0a0a",
        panel: "#10151f",
        line: "#223147",
        accent: "#00d4ff"
      },
      boxShadow: {
        glow: "0 0 0 1px rgba(0,212,255,0.28), 0 0 26px rgba(0,212,255,0.14), 0 0 46px rgba(112,73,255,0.12)"
      }
    }
  },
  plugins: []
};
