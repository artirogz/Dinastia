// M0 placeholder. Real screens start at M1 from design/screens.
export default function Home() {
  return (
    <main className="flex flex-1 flex-col justify-center gap-3 px-5 py-10">
      <h1 className="text-3xl font-semibold leading-tight">Династия Семьи</h1>
      <p className="text-base text-text-muted">Этап M0: каркас приложения готов.</p>
      <div className="mt-4 rounded-2xl border border-border bg-surface p-4">
        <p className="text-sm text-text-muted">
          Экраны курсов появятся на этапе M1 по макетам из design/screens.
        </p>
      </div>
    </main>
  );
}
