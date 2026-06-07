import getUnicodeFlagIcon from "country-flag-icons/unicode"
import { useEffect, useState } from "react"

import getEnv from "@/lib/env-entry"
import { cn, isEmojiFlag } from "@/lib/utils"

export default function ServerFlag({
  country_code,
  className,
}: {
  country_code: string
  className?: string
}) {
  const [supportsEmojiFlags, setSupportsEmojiFlags] = useState(true)
  const useSvgFlag = getEnv("NEXT_PUBLIC_ForceUseSvgFlag") === "true"

  useEffect(() => {
    if (useSvgFlag) {
      // 如果环境变量要求直接使用 SVG，则无需检查 Emoji 支持
      setSupportsEmojiFlags(false)
      return
    }

    const checkEmojiSupport = () => {
      const canvas = document.createElement("canvas")
      const ctx = canvas.getContext("2d")

      // 使用国旗测试（原项目这里是空字符串）
      const emojiFlag = "🇺🇸"
      if (!ctx) return

      ctx.fillStyle = "#000"
      ctx.textBaseline = "top"
      ctx.font = "32px Arial"
      ctx.fillText(emojiFlag, 0, 0)

      const support = ctx.getImageData(16, 16, 1, 1).data[3] !== 0
      setSupportsEmojiFlags(support)
    }

    checkEmojiSupport()
  }, [useSvgFlag])

  if (!country_code) return null

  const normalizedUpper = country_code.toUpperCase()
  const normalizedLower = country_code.toLowerCase()

  // ✅ 放大国旗：把默认字号从 12px 提升到 18px（你也可以改 20px）
  // flag-icons 的 .fi 尺寸是按 em 计算的，所以字号变大，SVG 国旗也会同步变大
  const baseClass = cn(
    "inline-flex items-center leading-none text-[18px] text-muted-foreground",
    className,
  )

  // If the country_code is already an emoji flag, display it directly
  if (isEmojiFlag(country_code)) {
    return <span className={baseClass}>{country_code}</span>
  }

  return (
    <span className={baseClass}>
      {useSvgFlag || !supportsEmojiFlags ? (
        <span className={`fi fi-${normalizedLower}`} />
      ) : (
        getUnicodeFlagIcon(normalizedUpper)
      )}
    </span>
  )
}
