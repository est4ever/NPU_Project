import { NavLink } from "react-router-dom";

const links = [
  { label: "Home", to: "/" },
  { label: "Docs", to: "/docs" },
  { label: "Quick Start", to: "/quick-start" },
  { label: "Architecture", to: "/architecture" },
  { label: "API", to: "/api" },
  { label: "CLI", to: "/cli" },
  { label: "Models", to: "/models" },
  { label: "FAQ", to: "/faq" },
];

export function Navbar() {
  return (
    <header className="fixed inset-x-0 top-0 z-50 border-b border-line/70 bg-page/90 backdrop-blur">
      <nav className="mx-auto flex max-w-6xl items-center justify-between px-4 py-3 sm:px-6 lg:px-8" aria-label="Main navigation">
        <NavLink to="/" className="text-lg font-semibold tracking-tight text-white">
          AcouLM
        </NavLink>
        <ul className="hidden items-center gap-4 text-sm text-slate-300 lg:flex">
          {links.map((item) => (
            <li key={item.label}>
              <NavLink
                to={item.to}
                end={item.to === "/"}
                className={({ isActive }) =>
                  isActive
                    ? "rounded-md border border-accent/70 bg-accent/10 px-3 py-1.5 text-accent"
                    : "rounded-md px-3 py-1.5 transition hover:text-accent"
                }
              >
                {item.label}
              </NavLink>
            </li>
          ))}
          <li>
            <a
              href="https://github.com/est4ever/AcouLM"
              target="_blank"
              rel="noreferrer"
              className="rounded-md border border-accent/60 px-3 py-1.5 text-accent transition hover:bg-accent/10"
            >
              GitHub
            </a>
          </li>
        </ul>
      </nav>
    </header>
  );
}
