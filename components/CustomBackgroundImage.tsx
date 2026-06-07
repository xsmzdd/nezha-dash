"use client"

import { useEffect } from "react"
import getEnv from "@/lib/env-entry"

export function CustomBackgroundImage() {
  useEffect(() => {
    const runtimeBackground = (window as any).CustomBackgroundImage
    const envBackground = getEnv("NEXT_PUBLIC_CustomBackgroundImage")
    const backgroundImage = runtimeBackground || envBackground

    if (typeof backgroundImage === "string" && backgroundImage.trim()) {
      document.documentElement.style.setProperty("--custom-background-image", `url("${backgroundImage.trim()}")`)
    }
  }, [])

  return null
}
