import Link from "next/link"
import { useTranslations } from "next-intl"
import CountryFlagBackdrop from "@/components/CountryFlagBackdrop"
import ServerFlag from "@/components/ServerFlag"
import ServerUsageBar from "@/components/ServerUsageBar"
import { Badge } from "@/components/ui/badge"
import { Card } from "@/components/ui/card"
import type { NezhaAPISafe } from "@/lib/drivers/types"
import getEnv from "@/lib/env-entry"
import { GetFontLogoClass, GetOsName, MageMicrosoftWindows } from "@/lib/logo-class"
import { cn, formatBytes, formatNezhaInfo } from "@/lib/utils"

export default function ServerCard({ serverInfo }: { serverInfo: NezhaAPISafe }) {
  const t = useTranslations("ServerCard")
  const { id, name, country_code, online, cpu, up, down, mem, stg, host } =
    formatNezhaInfo(serverInfo)

  const showFlag = getEnv("NEXT_PUBLIC_ShowFlag") === "true"
  const showNetTransfer = getEnv("NEXT_PUBLIC_ShowNetTransfer") === "true"
  const fixedTopServerName = getEnv("NEXT_PUBLIC_FixedTopServerName") === "true"

  const saveSession = () => {
    sessionStorage.setItem("fromMainPage", "true")
  }

  return online ? (
    <Link onClick={saveSession} href={`/server/${id}`} prefetch={true}>
      <Card
        className={cn(
          "server-glass-card relative flex cursor-pointer flex-col items-center justify-start gap-5 overflow-hidden p-4 transition-all hover:shadow-sm hover:ring-stone-300 md:px-6 dark:hover:ring-stone-700",
          {
            "flex-col": fixedTopServerName,
            "lg:flex-row": !fixedTopServerName,
          },
        )}
      >
        {showFlag ? <CountryFlagBackdrop country_code={country_code} direction="horizontal" /> : null}
        <section
          className={cn("relative z-10 grid items-center gap-2", {
            "lg:w-48": !fixedTopServerName,
          })}
          style={{ gridTemplateColumns: "auto auto 1fr" }}
        >
          <span className="h-2 w-2 shrink-0 self-center rounded-full bg-green-500" />
          <div
            className={cn(
              "flex items-center justify-center",
              showFlag ? "min-w-[17px]" : "min-w-0",
            )}
          >
            {showFlag ? <ServerFlag country_code={country_code} /> : null}
          </div>
          <div className="relative">
            <p
              className={cn(
                "break-normal font-bold tracking-tight",
                showFlag ? "text-[17px]" : "text-[15px]",
              )}
            >
              {name}
            </p>
          </div>
        </section>
        <div className="relative z-10 flex flex-col gap-2">
          <section
            className={cn("grid grid-cols-5 items-center gap-5", {
              "lg:grid-cols-6 lg:gap-6": fixedTopServerName,
            })}
          >
            {fixedTopServerName && (
              <div className={"col-span-1 hidden items-center gap-2 lg:flex lg:flex-row"}>
                <div className="font-semibold text-[13px]">
                  {host.Platform.includes("Windows") ? (
                    <MageMicrosoftWindows className="size-[10px]" />
                  ) : (
                    <p className={`fl-${GetFontLogoClass(host.Platform)}`} />
                  )}
                </div>
                <div className={"flex w-20 flex-col"}>
                  <p className="text-muted-foreground text-[13px]">{t("System")}</p>
                  <div className="flex items-center font-semibold text-[12px]">
                    {host.Platform.includes("Windows") ? "Windows" : GetOsName(host.Platform)}
                  </div>
                </div>
              </div>
            )}
            <div className={"flex w-20 flex-col"}>
              <p className="text-muted-foreground text-[13px]">{t("CPU")}</p>
              <div className="flex items-center font-semibold text-[13px]">{cpu.toFixed(2)}%</div>
              <ServerUsageBar value={cpu} />
            </div>
            <div className={"flex w-20 flex-col"}>
              <p className="text-muted-foreground text-[13px]">{t("Mem")}</p>
              <div className="flex items-center font-semibold text-[13px]">{mem.toFixed(2)}%</div>
              <ServerUsageBar value={mem} />
            </div>
            <div className={"flex w-20 flex-col"}>
              <p className="text-muted-foreground text-[13px]">{t("STG")}</p>
              <div className="flex items-center font-semibold text-[13px]">{stg.toFixed(2)}%</div>
              <ServerUsageBar value={stg} />
            </div>
            <div className={"flex w-20 flex-col"}>
              <p className="text-muted-foreground text-[13px]">{t("Upload")}</p>
              <div className="flex items-center font-semibold text-[13px]">
                {up >= 1024 ? `${(up / 1024).toFixed(2)}G/s` : `${up.toFixed(2)}M/s`}
              </div>
            </div>
            <div className={"flex w-20 flex-col"}>
              <p className="text-muted-foreground text-[13px]">{t("Download")}</p>
              <div className="flex items-center font-semibold text-[13px]">
                {down >= 1024 ? `${(down / 1024).toFixed(2)}G/s` : `${down.toFixed(2)}M/s`}
              </div>
            </div>
          </section>
          {showNetTransfer && (
            <section className={"flex items-center justify-between gap-1"}>
              <Badge
                variant="secondary"
                className="flex-1 items-center justify-center text-nowrap rounded-[8px] border-muted-50 text-[12px] shadow-md shadow-neutral-200/30 dark:shadow-none"
              >
                {t("Upload")}:{formatBytes(serverInfo.status.NetOutTransfer)}
              </Badge>
              <Badge
                variant="outline"
                className="flex-1 items-center justify-center text-nowrap rounded-[8px] text-[12px] shadow-md shadow-neutral-200/30 dark:shadow-none"
              >
                {t("Download")}:{formatBytes(serverInfo.status.NetInTransfer)}
              </Badge>
            </section>
          )}
        </div>
      </Card>
    </Link>
  ) : (
    <Link onClick={saveSession} href={`/server/${id}`} prefetch={true}>
      <Card
        className={cn(
          "server-glass-card relative flex cursor-pointer flex-col items-center justify-start gap-5 overflow-hidden p-4 transition-all hover:shadow-sm hover:ring-stone-300 md:px-6 dark:hover:ring-stone-700",
          showNetTransfer ? "min-h-[132px] lg:min-h-[104px]" : "min-h-[104px] lg:min-h-[74px]",
          {
            "flex-col": fixedTopServerName,
            "lg:flex-row": !fixedTopServerName,
          },
        )}
      >
        {showFlag ? <CountryFlagBackdrop country_code={country_code} direction="horizontal" /> : null}
        <section
          className={cn("relative z-10 grid items-center gap-2", {
            "lg:w-48": !fixedTopServerName,
          })}
          style={{ gridTemplateColumns: "auto auto 1fr" }}
        >
          <span className="h-2 w-2 shrink-0 self-center rounded-full bg-red-500" />
          <div
            className={cn(
              "flex items-center justify-center",
              showFlag ? "min-w-[17px]" : "min-w-0",
            )}
          >
            {showFlag ? <ServerFlag country_code={country_code} /> : null}
          </div>
          <div className="relative">
            <p
              className={cn(
                "break-normal font-bold tracking-tight",
                showFlag ? "text-[13px]" : "text-[13px]",
              )}
            >
              {name}
            </p>
          </div>
        </section>
      </Card>
    </Link>
  )
}
