import { cn, isEmojiFlag } from "@/lib/utils"

export default function CountryFlagBackdrop({
  country_code,
  direction,
  className,
}: {
  country_code: string
  direction: "vertical" | "horizontal"
  className?: string
}) {
  if (!country_code || isEmojiFlag(country_code)) return null

  const normalizedLower = country_code.toLowerCase()

  return (
    <span
      aria-hidden="true"
      className={cn(
        "fi",
        `fi-${normalizedLower}`,
        "server-card-flag-backdrop",
        direction === "vertical"
          ? "server-card-flag-backdrop--vertical"
          : "server-card-flag-backdrop--horizontal",
        className,
      )}
    />
  )
}
