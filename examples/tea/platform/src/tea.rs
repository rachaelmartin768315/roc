use crate::graphics::{
    lowlevel::buffer::create_rect_buffers, lowlevel::ortho::update_ortho_buffer,
    lowlevel::pipelines, primitives::rect::Rect, primitives::text::build_glyph_brush,
};
use pipelines::RectResources;
use roc_std::RocStr;
use std::error::Error;
use wgpu::{CommandEncoder, LoadOp, RenderPass, TextureView};
use winit::{
    dpi::PhysicalSize,
    event,
    event::{Event, ModifiersState},
    event_loop::ControlFlow,
    platform::run_return::EventLoopExtRunReturn,
};

// Inspired by:
// https://github.com/sotrh/learn-wgpu by Benjamin Hansen, which is licensed under the MIT license
// https://github.com/cloudhead/rgx by Alexis Sellier, which is licensed under the MIT license
//
// See this link to learn wgpu: https://sotrh.github.io/learn-wgpu/

fn run_event_loop(title: &str) -> Result<(), Box<dyn Error>> {
    // Open window and create a surface
    let mut event_loop = winit::event_loop::EventLoop::new();
    let mut needs_repaint = true;

    let window = winit::window::WindowBuilder::new()
        .with_inner_size(PhysicalSize::new(1900.0, 1000.0))
        .with_title("The Roc Editor - Work In Progress")
        .build(&event_loop)
        .unwrap();

    let instance = wgpu::Instance::new(wgpu::Backends::all());

    let surface = unsafe { instance.create_surface(&window) };

    // Initialize GPU
    let (gpu_device, cmd_queue) = futures::executor::block_on(async {
        let adapter = instance
            .request_adapter(&wgpu::RequestAdapterOptions {
                power_preference: wgpu::PowerPreference::HighPerformance,
                compatible_surface: Some(&surface),
                force_fallback_adapter: false,
            })
            .await
            .expect(r#"Request adapter
            If you're running this from inside nix, follow the instructions here to resolve this: https://github.com/rtfeldman/roc/blob/trunk/BUILDING_FROM_SOURCE.md#editor
            "#);

        adapter
            .request_device(
                &wgpu::DeviceDescriptor {
                    label: None,
                    features: wgpu::Features::empty(),
                    limits: wgpu::Limits::default(),
                },
                None,
            )
            .await
            .expect("Request device")
    });

    // Create staging belt and a local pool
    let mut staging_belt = wgpu::util::StagingBelt::new(1024);
    let mut local_pool = futures::executor::LocalPool::new();
    let local_spawner = local_pool.spawner();

    // Prepare swap chain
    let render_format = wgpu::TextureFormat::Bgra8Unorm;
    let mut size = window.inner_size();

    let surface_config = wgpu::SurfaceConfiguration {
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
        format: render_format,
        width: size.width,
        height: size.height,
        present_mode: wgpu::PresentMode::Mailbox,
    };

    surface.configure(&gpu_device, &surface_config);

    let rect_resources = pipelines::make_rect_pipeline(&gpu_device, &surface_config);

    let mut glyph_brush = build_glyph_brush(&gpu_device, render_format)?;

    let is_animating = true;

    let mut keyboard_modifiers = ModifiersState::empty();

    // Render loop
    window.request_redraw();

    event_loop.run_return(|event, _, control_flow| {
        // TODO dynamically switch this on/off depending on whether any
        // animations are running. Should conserve CPU usage and battery life!
        if is_animating {
            *control_flow = ControlFlow::Poll;
        } else {
            *control_flow = ControlFlow::Wait;
        }

        match event {
            //Close
            Event::WindowEvent {
                event: event::WindowEvent::CloseRequested,
                ..
            } => *control_flow = ControlFlow::Exit,
            //Resize
            Event::WindowEvent {
                event: event::WindowEvent::Resized(new_size),
                ..
            } => {
                size = new_size;

                surface.configure(
                    &gpu_device,
                    &wgpu::SurfaceConfiguration {
                        usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                        format: render_format,
                        width: size.width,
                        height: size.height,
                        present_mode: wgpu::PresentMode::Mailbox,
                    },
                );

                update_ortho_buffer(
                    size.width,
                    size.height,
                    &gpu_device,
                    &rect_resources.ortho.buffer,
                    &cmd_queue,
                );
            }
            //Received Character
            Event::WindowEvent {
                event: event::WindowEvent::ReceivedCharacter(ch),
                ..
            } => {
                // let input_outcome_res =
                //     app_update::handle_new_char(&ch, &mut app_model, keyboard_modifiers);
                // if let Err(e) = input_outcome_res {
                //     print_err(&e)
                // } else if let Ok(InputOutcome::Ignored) = input_outcome_res {
                //     println!("Input '{}' ignored!", ch);
                // }
                todo!("TODO handle character input");
            }
            //Keyboard Input
            Event::WindowEvent {
                event: event::WindowEvent::KeyboardInput { input, .. },
                ..
            } => {
                // if let Some(virtual_keycode) = input.virtual_keycode {
                //     if let Some(ref mut ed_model) = app_model.ed_model_opt {
                //         if ed_model.has_focus {
                //             let keydown_res = keyboard_input::handle_keydown(
                //                 input.state,
                //                 virtual_keycode,
                //                 keyboard_modifiers,
                //                 &mut app_model,
                //             );

                //             if let Err(e) = keydown_res {
                //                 print_err(&e)
                //             }
                //         }
                //     }
                // }
                todo!("TODO handle keyboard input");
            }
            //Modifiers Changed
            Event::WindowEvent {
                event: event::WindowEvent::ModifiersChanged(modifiers),
                ..
            } => {
                keyboard_modifiers = modifiers;
            }
            Event::MainEventsCleared => window.request_redraw(),
            Event::RedrawRequested { .. } => {
                // Get a command encoder for the current frame
                let mut encoder =
                    gpu_device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
                        label: Some("Redraw"),
                    });

                let surface_texture = surface
                    .get_current_texture()
                    .expect("Failed to acquire next SwapChainTexture");

                let view = surface_texture
                    .texture
                    .create_view(&wgpu::TextureViewDescriptor::default());

                // for text_section in &rendered_wgpu.text_sections_behind {
                //     let borrowed_text = text_section.to_borrowed();

                //     glyph_brush.queue(borrowed_text);
                // }

                // draw first layer of text
                glyph_brush
                    .draw_queued(
                        &gpu_device,
                        &mut staging_belt,
                        &mut encoder,
                        &view,
                        size.width,
                        size.height,
                    )
                    .expect("Failed to draw first layer of text.");

                // draw rects on top of first text layer
                // draw_rects(
                //     &rendered_wgpu.rects_front,
                //     &mut encoder,
                //     &view,
                //     &gpu_device,
                //     &rect_resources,
                //     wgpu::LoadOp::Load,
                // );

                // for text_section in &rendered_wgpu.text_sections_front {
                //     let borrowed_text = text_section.to_borrowed();

                //     glyph_brush.queue(borrowed_text);
                // }

                // draw text
                glyph_brush
                    .draw_queued(
                        &gpu_device,
                        &mut staging_belt,
                        &mut encoder,
                        &view,
                        size.width,
                        size.height,
                    )
                    .expect("Failed to draw queued text.");

                staging_belt.finish();
                cmd_queue.submit(Some(encoder.finish()));
                surface_texture.present();

                // Recall unused staging buffers
                use futures::task::SpawnExt;

                local_spawner
                    .spawn(staging_belt.recall())
                    .expect("Recall staging belt");

                local_pool.run_until_stalled();
            }
            _ => {
                *control_flow = winit::event_loop::ControlFlow::Wait;
            }
        }
    });

    Ok(())
}

fn draw_rects(
    all_rects: &[Rect],
    encoder: &mut CommandEncoder,
    texture_view: &TextureView,
    gpu_device: &wgpu::Device,
    rect_resources: &RectResources,
    load_op: LoadOp<wgpu::Color>,
) {
    let rect_buffers = create_rect_buffers(gpu_device, encoder, all_rects);

    let mut render_pass = begin_render_pass(encoder, texture_view, load_op);

    render_pass.set_pipeline(&rect_resources.pipeline);
    render_pass.set_bind_group(0, &rect_resources.ortho.bind_group, &[]);
    render_pass.set_vertex_buffer(0, rect_buffers.vertex_buffer.slice(..));
    render_pass.set_index_buffer(
        rect_buffers.index_buffer.slice(..),
        wgpu::IndexFormat::Uint32,
    );
    render_pass.draw_indexed(0..rect_buffers.num_rects, 0, 0..1);
}

fn begin_render_pass<'a>(
    encoder: &'a mut CommandEncoder,
    texture_view: &'a TextureView,
    load_op: LoadOp<wgpu::Color>,
) -> RenderPass<'a> {
    encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
        color_attachments: &[wgpu::RenderPassColorAttachment {
            view: texture_view,
            resolve_target: None,
            ops: wgpu::Operations {
                load: load_op,
                store: true,
            },
        }],
        depth_stencil_attachment: None,
        label: None,
    })
}

pub fn render(title: RocStr) {
    run_event_loop(title.as_str()).expect("Error running event loop")
}
