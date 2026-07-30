#define SDL_MAIN_HANDLED
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <SDL3/SDL_opengles2.h>
#include <stdio.h>

int main(void)
{
    SDL_Window *window = NULL;
    SDL_GLContext context = NULL;
    Uint64 started;
    int running = 1;

    SDL_SetMainReady();
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_ES);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0);
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);

    if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS)) {
        fprintf(stderr, "xios-sdl3-smoke: SDL_Init: %s\n", SDL_GetError());
        return 1;
    }

    window = SDL_CreateWindow("SDL3 on Xios", 960, 640,
                              SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE |
                                  SDL_WINDOW_HIGH_PIXEL_DENSITY);
    if (!window) {
        fprintf(stderr, "xios-sdl3-smoke: SDL_CreateWindow: %s\n", SDL_GetError());
        SDL_Quit();
        return 2;
    }

    context = SDL_GL_CreateContext(window);
    if (!context) {
        fprintf(stderr, "xios-sdl3-smoke: SDL_GL_CreateContext: %s\n", SDL_GetError());
        SDL_DestroyWindow(window);
        SDL_Quit();
        return 3;
    }

    SDL_GL_SetSwapInterval(1);
    {
        int touch_count = 0;
        SDL_TouchID *touches = SDL_GetTouchDevices(&touch_count);
        fprintf(stderr,
                "XIOS_SDL_SMOKE_READY api=SDL3 driver=%s renderer=%s version=%s touch=%d\n",
                SDL_GetCurrentVideoDriver(),
                (const char *)glGetString(GL_RENDERER),
                (const char *)glGetString(GL_VERSION),
                touch_count);
        SDL_free(touches);
    }

    started = SDL_GetTicks();
    while (running && SDL_GetTicks() - started < 120000) {
        SDL_Event event;
        int width = 1;
        int height = 1;
        float phase = (float)((SDL_GetTicks() - started) % 6000) / 6000.0f;

        while (SDL_PollEvent(&event)) {
            if (event.type == SDL_EVENT_QUIT ||
                (event.type == SDL_EVENT_KEY_DOWN && event.key.key == SDLK_ESCAPE)) {
                running = 0;
            }
        }

        SDL_GetWindowSizeInPixels(window, &width, &height);
        glViewport(0, 0, width, height);
        glClearColor(0.08f, 0.42f - phase * 0.18f, 0.18f + phase * 0.22f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        SDL_GL_SwapWindow(window);
    }

    SDL_GL_DestroyContext(context);
    SDL_DestroyWindow(window);
    SDL_Quit();
    return 0;
}
