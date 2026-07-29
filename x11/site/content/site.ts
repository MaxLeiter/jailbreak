export type NavItem = {
  href: string;
  label: string;
  idx: string;
};

export const NAV: NavItem[] = [
  { href: "/", label: "Overview", idx: "00" },
  { href: "/architecture", label: "Architecture", idx: "01" },
  { href: "/display-servers", label: "Display servers", idx: "02" },
  { href: "/graphics", label: "The GPU path", idx: "03" },
  { href: "/flavors", label: "Desktop flavors", idx: "04" },
  { href: "/build", label: "Build & packaging", idx: "05" },
  { href: "/system", label: "System integration", idx: "06" },
  { href: "/accessibility", label: "Accessibility", idx: "07" },
  { href: "/try", label: "Try it yourself", idx: "08" },
  { href: "/contributing", label: "Contributing", idx: "09" },
];

export const SITE = {
  name: "xiOS",
  tagline: "A native Linux desktop on jailbroken iOS.",
  repo: "https://repo.maxleiter.com",
  device: "Reference device: iPad 7 (A10), iPadOS 17.6.1",
};

export function siblings(href: string) {
  const i = NAV.findIndex((n) => n.href === href);
  return {
    prev: i > 0 ? NAV[i - 1] : null,
    next: i >= 0 && i < NAV.length - 1 ? NAV[i + 1] : null,
  };
}
