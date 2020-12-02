#![warn(clippy::all, clippy::dbg_macro)]
// I'm skeptical that clippy:large_enum_variant is a good lint to have globally enabled.
//
// It warns about a performance problem where the only quick remediation is
// to allocate more on the heap, which has lots of tradeoffs - including making it
// long-term unclear which allocations *need* to happen for compilation's sake
// (e.g. recursive structures) versus those which were only added to appease clippy.
//
// Effectively optimizing data structure memory layout isn't a quick fix,
// and encouraging shortcuts here creates bad incentives. I would rather temporarily
// re-enable this when working on performance optimizations than have it block PRs.
#![allow(clippy::large_enum_variant)]


// See this link to learn wgpu: https://sotrh.github.io/learn-wgpu/

use crate::rect::Rect;
use crate::vertex::Vertex;
use std::error::Error;
use std::io;
use std::path::Path;
use wgpu::util::DeviceExt;
use wgpu_glyph::{ab_glyph, GlyphBrushBuilder, Section, Text};
use winit::event::{ElementState, ModifiersState, VirtualKeyCode, Event};
use winit::event;
use winit::event_loop::ControlFlow;


pub mod ast;
mod rect;
pub mod text_state;
mod vertex;

/// The editor is actually launched from the CLI if you pass it zero arguments,
/// or if you provide it 1 or more files or directories to open on launch.
pub fn launch(_filepaths: &[&Path]) -> io::Result<()> {
    // TODO do any initialization here

    run_event_loop().expect("Error running event loop");

    Ok(())
}

fn run_event_loop() -> Result<(), Box<dyn Error>> {
    env_logger::init();

    // Open window and create a surface
    let event_loop = winit::event_loop::EventLoop::new();

    let window = winit::window::WindowBuilder::new()
        .build(&event_loop)
        .unwrap();

    let instance = wgpu::Instance::new(wgpu::BackendBit::all());

    let surface = unsafe { instance.create_surface(&window) };

    // Initialize GPU
    let (gpu_device, cmd_queue) = futures::executor::block_on(async {
        let adapter = instance
            .request_adapter(&wgpu::RequestAdapterOptions {
                power_preference: wgpu::PowerPreference::HighPerformance,
                compatible_surface: Some(&surface),
            })
            .await
            .expect("Request adapter");

        adapter
            .request_device(
                &wgpu::DeviceDescriptor {
                    features: wgpu::Features::empty(),
                    limits: wgpu::Limits::default(),
                    shader_validation: false,
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
    let render_format = wgpu::TextureFormat::Bgra8UnormSrgb;
    let mut size = window.inner_size();
    let mut swap_chain = gpu_device.create_swap_chain(
        &surface,
        &wgpu::SwapChainDescriptor {
            usage: wgpu::TextureUsage::OUTPUT_ATTACHMENT,
            format: render_format,
            width: size.width,
            height: size.height,
            //Immediate may cause tearing, change present_mode if this becomes a problem
            present_mode: wgpu::PresentMode::Immediate,
        },
    );

    let rect_pipeline = make_rect_pipeline(&gpu_device);

    // Prepare glyph_brush
    let inconsolata =
        ab_glyph::FontArc::try_from_slice(include_bytes!("../Inconsolata-Regular.ttf"))?;

    let mut glyph_brush = GlyphBrushBuilder::using_font(inconsolata).build(&gpu_device, render_format);

    let is_animating = true;
    let mut text_state = String::new();
    let mut keyboard_modifiers = ModifiersState::empty();

    // Render loop
    window.request_redraw();

    event_loop.run(move |event, _, control_flow| {
        // TODO dynamically switch this on/off depending on whether any
        // animations are running. Should conserve CPU usage and battery life!
        if is_animating {
            *control_flow = ControlFlow::Poll;
        } else {
            *control_flow = ControlFlow::Wait;
        }

        match event {
            Event::WindowEvent {
                event: event::WindowEvent::CloseRequested,
                ..
            } => *control_flow = winit::event_loop::ControlFlow::Exit,
            Event::WindowEvent {
                event: event::WindowEvent::Resized(new_size),
                ..
            } => {
                size = new_size;

                swap_chain = gpu_device.create_swap_chain(
                    &surface,
                    &wgpu::SwapChainDescriptor {
                        usage: wgpu::TextureUsage::OUTPUT_ATTACHMENT,
                        format: render_format,
                        width: size.width,
                        height: size.height,
                        //Immediate may cause tearing, change present_mode if this becomes a problem
                        present_mode: wgpu::PresentMode::Immediate,
                    },
                );
            }
            Event::WindowEvent {
                event: event::WindowEvent::ReceivedCharacter(ch),
                ..
            } => {
                update_text_state(&mut text_state, &ch);
            }
            Event::WindowEvent {
                event: event::WindowEvent::KeyboardInput { input, .. },
                ..
            } => {
                if let Some(virtual_keycode) = input.virtual_keycode {
                    handle_keydown(input.state, virtual_keycode, keyboard_modifiers);
                }
            }
            Event::WindowEvent {
                event: event::WindowEvent::ModifiersChanged(modifiers),
                ..
            } => {
                keyboard_modifiers = modifiers;
            }
            Event::MainEventsCleared => window.request_redraw(),
            Event::RedrawRequested { .. } => {
                // Get a command encoder for the current frame
                let mut encoder = gpu_device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
                    label: Some("Redraw"),
                });

                // Get the next frame
                let frame = swap_chain
                    .get_current_frame()
                    .expect("Failed to acquire next swap chain texture")
                    .output;

                let rect_buffers =
                    create_rect_buffers(&gpu_device);

                // Clear frame
                clear_frame(&mut encoder, &frame, &rect_pipeline, &rect_buffers);

                draw_text(&gpu_device, &mut staging_belt, &mut encoder, &frame, &size, &text_state, &mut glyph_brush);

                staging_belt.finish();
                cmd_queue.submit(Some(encoder.finish()));

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
    })
}

fn make_rect_pipeline(gpu_device: &wgpu::Device) -> wgpu::RenderPipeline {
    let rect_vs_module =
        gpu_device.create_shader_module(wgpu::include_spirv!("shaders/rect.vert.spv"));
    let rect_fs_module =
    gpu_device.create_shader_module(wgpu::include_spirv!("shaders/rect.frag.spv"));

    let pipeline_layout = gpu_device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
        label: None,
        bind_group_layouts: &[],
        push_constant_ranges: &[],
    });

    gpu_device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
        label: None,
        layout: Some(&pipeline_layout),
        vertex_stage: wgpu::ProgrammableStageDescriptor {
            module: &rect_vs_module,
            entry_point: "main",
        },
        fragment_stage: Some(wgpu::ProgrammableStageDescriptor {
            module: &rect_fs_module,
            entry_point: "main",
        }),
        // Use the default rasterizer state: no culling, no depth bias
        rasterization_state: None,
        primitive_topology: wgpu::PrimitiveTopology::TriangleList,
        color_states: &[wgpu::TextureFormat::Bgra8UnormSrgb.into()],
        depth_stencil_state: None,
        vertex_state: wgpu::VertexStateDescriptor {
            index_format: wgpu::IndexFormat::Uint16,
            vertex_buffers: &[Vertex::buffer_descriptor()],
        },
        sample_count: 1,
        sample_mask: !0,
        alpha_to_coverage_enabled: false,
    })
}

struct RectBuffers {
    rect_index_buffers: Vec<u16>,
    vertex_buffer: wgpu::Buffer,
    index_buffer: wgpu::Buffer
}

fn create_rect_buffers(gpu_device: &wgpu::Device) -> RectBuffers {
    // Test Rectangle
    let test_rect_1 = Rect {
        top: 0.9,
        left: -0.8,
        width: 0.2,
        height: 0.3,
        color: [0.0, 1.0, 1.0],
    };
    let test_rect_2 = Rect {
        top: 0.0,
        left: 0.0,
        width: 0.5,
        height: 0.5,
        color: [1.0, 1.0, 0.0],
    };
    let mut rect = Vec::new();
    rect.extend_from_slice(&test_rect_1.as_array());
    rect.extend_from_slice(&test_rect_2.as_array());

    let mut rect_index_buffers = Vec::new();
    rect_index_buffers.extend_from_slice(&Rect::INDEX_BUFFER);
    rect_index_buffers.extend_from_slice(&Rect::INDEX_BUFFER);
    // Vertex Buffer for drawing rectangles
    let vertex_buffer = gpu_device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
        label: Some("Vertex Buffer"),
        contents: bytemuck::cast_slice(&rect),
        usage: wgpu::BufferUsage::VERTEX,
    });

    // Index Buffer for drawing rectangles
    let index_buffer = gpu_device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
        label: Some("Index Buffer"),
        contents: bytemuck::cast_slice(&rect_index_buffers),
        usage: wgpu::BufferUsage::INDEX,
    });

    RectBuffers {rect_index_buffers, vertex_buffer, index_buffer}
}

fn clear_frame(
    encoder: &mut wgpu::CommandEncoder,
    frame: &wgpu::SwapChainTexture,
    rect_pipeline: &wgpu::RenderPipeline,
    rect_buffers: &RectBuffers
) {
    let mut render_pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
        color_attachments: &[wgpu::RenderPassColorAttachmentDescriptor {
            attachment: &frame.view,
            resolve_target: None,
            ops: wgpu::Operations {
                load: wgpu::LoadOp::Clear(wgpu::Color {
                    r: 0.007,
                    g: 0.007,
                    b: 0.007,
                    a: 1.0,
                }),
                store: true,
            },
        }],
        depth_stencil_attachment: None,
    });

    render_pass.set_pipeline(rect_pipeline);

    render_pass.set_vertex_buffer(
        0,                       // The buffer slot to use for this vertex buffer.
        rect_buffers.vertex_buffer.slice(..), // Use the entire buffer.
    );

    render_pass.set_index_buffer(
        rect_buffers.index_buffer.slice(..)
    );

    render_pass.draw_indexed(
        0..((rect_buffers.rect_index_buffers).len() as u32), // Draw all of the vertices from our test data.
        0,                                       // Base Vertex
        0..1,                                    // Instances
    );
}

fn draw_text(
    gpu_device: &wgpu::Device,
    staging_belt: &mut wgpu::util::StagingBelt,
    encoder: &mut wgpu::CommandEncoder,
    frame: &wgpu::SwapChainTexture,
    size: &winit::dpi::PhysicalSize<u32>,
    text_state: &str,
    glyph_brush: &mut wgpu_glyph::GlyphBrush<()>) {
    glyph_brush.queue(Section {
        screen_position: (30.0, 30.0),
        bounds: (size.width as f32, size.height as f32),
        text: vec![Text::new("Enter some text:")
            .with_color([0.4666, 0.2, 1.0, 1.0])
            .with_scale(40.0)],
        ..Section::default()
    });

    glyph_brush.queue(Section {
        screen_position: (30.0, 90.0),
        bounds: (size.width as f32, size.height as f32),
        text: vec![Text::new(format!("{}|", text_state).as_str())
            .with_color([1.0, 1.0, 1.0, 1.0])
            .with_scale(40.0)],
        ..Section::default()
    });

    // Draw the text!
    glyph_brush
        .draw_queued(
            gpu_device,
            staging_belt,
            encoder,
            &frame.view,
            size.width,
            size.height,
        )
        .expect("Draw queued");
}

fn update_text_state(text_state: &mut String, received_char: &char) {
    match received_char {
        '\u{8}' | '\u{7f}' => {
            // In Linux, we get a '\u{8}' when you press backspace,
            // but in macOS we get '\u{7f}'.
            text_state.pop();
        }
        '\u{e000}'..='\u{f8ff}'
        | '\u{f0000}'..='\u{ffffd}'
        | '\u{100000}'..='\u{10fffd}' => {
            // These are private use characters; ignore them.
            // See http://www.unicode.org/faq/private_use.html
        }
        _ => {
            text_state.push(*received_char);
        }
    }
}

fn handle_keydown(
    elem_state: ElementState,
    virtual_keycode: VirtualKeyCode,
    _modifiers: ModifiersState,
) {
    use winit::event::VirtualKeyCode::*;

    if let ElementState::Released = elem_state {
        return;
    }

    match virtual_keycode {
        Copy => {
            todo!("copy");
        }
        Paste => {
            todo!("paste");
        }
        Cut => {
            todo!("cut");
        }
        _ => {}
    }
}
