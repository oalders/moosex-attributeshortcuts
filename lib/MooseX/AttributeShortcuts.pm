package MooseX::AttributeShortcuts;

# ABSTRACT: Shorthand for common attribute options

use strict;
use warnings;

use namespace::autoclean;

use Moose ();
use Moose::Exporter;
use Moose::Util::MetaRole;
use Moose::Util::TypeConstraints;

# debug...
#use Smart::Comments;

{
    package MooseX::AttributeShortcuts::Trait::Attribute;
    use namespace::autoclean;
    use MooseX::Role::Parameterized;
    use Moose::Util::TypeConstraints qw{ class_type role_type enum };
    use MooseX::Types::Moose          ':all';
    use MooseX::Types::Common::String ':all';

    sub _find_or_create_isa_type_constraint { goto \&Moose::Util::TypeConstraints::find_or_create_isa_type_constraint }

    parameter writer_prefix  => (isa => NonEmptySimpleStr, default => '_set_');
    parameter builder_prefix => (isa => NonEmptySimpleStr, default => '_build_');

    # I'm not going to document the following for the moment, as I'm not sure I
    # want to do it this way.
    parameter prefixes => (
        isa     => HashRef[NonEmptySimpleStr],
        default => sub { { } },
    );

    role {
        my $p = shift @_;

        with 'MooseX::CoercePerAttribute' => { -version => 0.802 };

        my $wprefix = $p->writer_prefix;
        my $bprefix = $p->builder_prefix;
        my %prefix = (
            predicate => 'has',
            clearer   => 'clear',
            trigger   => '_trigger_',
            %{ $p->prefixes },
        );

        has anon_builder => (
            reader    => 'anon_builder',
            writer    => '_set_anon_builder',
            isa       => 'CodeRef',
            predicate => 'has_anon_builder',
            init_arg  => '_anon_builder',
        );

        has constraint => (
            is        => 'ro',
            isa       => 'CodeRef',
            predicate => 'has_constraint',
        );

        has original_isa => (
            is        => 'ro',
            predicate => 'has_original_isa',
        );

        # TODO coerce via, transform ?

        # has original_isa, original_coerce ?

        my $_process_options = sub {
            my ($class, $name, $options) = @_;

            my $_has = sub { defined $options->{$_[0]}             };
            my $_opt = sub { $_has->(@_) ? $options->{$_[0]} : q{} };
            my $_ref = sub { ref $_opt->(@_) || q{}                };

            if ($options->{is}) {

                if ($options->{is} eq 'rwp') {

                    $options->{is}     = 'ro';
                    $options->{writer} = "$wprefix$name";
                }

                if ($options->{is} eq 'lazy') {

                    $options->{is}       = 'ro';
                    $options->{lazy}     = 1;
                    $options->{builder}  = 1
                        unless $_has->('builder') || $_has->('default');
                }
            }

            # TODO isa_class - anon class_type generation
            # TODO isa_role  - anon role_type generation
            # TODO isa_enum  - anon enum generation
            # TODO coerce_via - anon coercion (type -> anon subtype+coercion

            # XXX we also ignore conflicts here -- last in wins
            #confess q{conflict 'isa' and 'isa_class' or 'isa_role'}
                #if $_has->('isa')

            # XXX undocumented -- not sure this is a great idea
            $options->{isa} = class_type(delete $options->{isa_class})
                if $_has->('isa_class');
            $options->{isa} = role_type(delete $options->{isa_role})
                if $_has->('isa_role');
            $options->{isa} = enum(delete $options->{isa_enum})
                if $_has->('isa_enum');

            ### the pretty business of on-the-fly subtyping...
            if ($_has->('constraint')) {

                # check for errors...
                $class->throw_error('You must specify an "isa" when declaring a "constraint"')
                    if !$_has->('isa');
                $class->throw_error('"constraint" must be a CODE reference')
                    if $_ref->('constraint') ne 'CODE';

                # constraint checking! XXX message, etc?
                push my @opts, constraint => $_opt->('constraint')
                    if $_ref->('constraint') eq 'CODE';

                # stash our original option away and construct our new one
                my $isa = $options->{original_isa} = $_opt->('isa');
                my $isa_tc = _find_or_create_isa_type_constraint($isa);
                my $new_tc = $isa_tc->create_child_type(@opts);

                if ($isa_tc->has_coercion && $_opt->('coerce') eq "1") {

                    # create our coercion as a copy of the parent
                    $new_tc->coercion(Moose::Meta::TypeCoercion->new(
                        type_constraint   => $new_tc,
                        type_coercion_map => $isa_tc->coercion->type_coercion_map,
                    ));
                }

                # fin constraint mucking....
                $options->{isa} = $new_tc;
            }

            if ($options->{lazy_build} && $options->{lazy_build} eq 'private') {

                $options->{lazy_build} = 1;
                $options->{clearer}    = "_clear_$name";
                $options->{predicate}  = "_has_$name";
            }

            my $is_private = sub { $name =~ /^_/ ? $_[0] : $_[1] };
            my $default_for = sub {
                my ($opt) = @_;

                return unless $_has->($opt);
                my $opt_val = $_opt->($opt);

                my ($head, $mid)
                    = $opt_val eq '1'  ? ($is_private->('_', q{}), $is_private->(q{}, '_'))
                    : $opt_val eq '-1' ? ($is_private->(q{}, '_'), $is_private->(q{}, '_'))
                    :                    return;

                $options->{$opt} = $head . $prefix{$opt} . $mid . $name;
                return;
            };

            # XXX install builder here if a coderef
            if (defined $options->{builder}) {

                #if (ref $_opt->('builder') eq 'CODE') {
                if ((ref $options->{builder} || q{}) eq 'CODE') {

                    $options->{_anon_builder} = $options->{builder};
                    $options->{builder}       = 1;
                }

                $options->{builder} = "$bprefix$name"
                    if $options->{builder} eq '1';
            }
            ### set our other defaults, if requested...
            $default_for->($_) for qw{ predicate clearer };
            my $trigger = "$prefix{trigger}$name";
            $options->{trigger} = sub { shift->$trigger(@_) }
                if $options->{trigger} && $options->{trigger} eq '1';

            return;
        };

        # here we wrap _process_options() instead of the newer _process_is_option(),
        # as that makes our life easier from a 1.x/2.x compatibility
        # perspective -- and that we're potentially altering more than just
        # the 'is' option at one time.

        before _process_options => $_process_options;

        # this feels... bad.  But I'm not sure there's any way to ensure we
        # process options on a clone/extends without wrapping new().

        around new => sub {
            my ($orig, $self) = (shift, shift);
            my ($name, %options) = @_;

            $self->$_process_options($name, \%options)
                if $options{__hack_no_process_options};

            return $self->$orig($name, %options);
        };


        # we hijack attach_to_class in order to install our anon_builder, if
        # we have one.  Note that we don't go the normal
        # associate_method/install_accessor/etc route as this is kinda...
        # different.

        after attach_to_class => sub {
            my ($self, $class) = @_;

            return unless $self->has_anon_builder;

            $class->add_method($self->builder => $self->anon_builder);
            return;
        };
    };
}

my ($import, $unimport, $init_meta) = Moose::Exporter->build_import_methods(
    install => [ 'unimport' ],
    trait_aliases => [
        [ 'MooseX::AttributeShortcuts::Trait::Attribute' => 'Shortcuts' ],
    ],
);

my $role_params;

sub import {
    my ($class, %args) = @_;

    $role_params = {};
    do { $role_params->{$_} = delete $args{"-$_"} if exists $args{"-$_"} }
        for qw{ writer_prefix builder_prefix prefixes };

    @_ = ($class, %args);
    goto &$import;
}

sub init_meta {
    my ($class_name, %args) = @_;
    my $params = delete $args{role_params} || $role_params || undef;
    undef $role_params;

    # Just in case we do ever start to get an $init_meta from ME
    $init_meta->($class_name, %args)
        if $init_meta;

    # make sure we have a metaclass instance kicking around
    my $for_class = $args{for_class};
    die "Class $for_class has no metaclass!"
        unless Class::MOP::class_of($for_class);

    # If we're given paramaters to pass on to construct a role with, we build
    # it out here rather than pass them on and allowing apply_metaroles() to
    # handle it, as there are Very Loud Warnings about how paramatized roles
    # are non-cachable when generated on the fly.

    ### $params
    my $role
        = ($params && scalar keys %$params)
        ? MooseX::AttributeShortcuts::Trait::Attribute
            ->meta
            ->generate_role(parameters => $params)
        : 'MooseX::AttributeShortcuts::Trait::Attribute'
        ;

    Moose::Util::MetaRole::apply_metaroles(
        for             => $for_class,
        class_metaroles => { attribute         => [ $role ] },
        # TODO add attribute trait here to create builder method if found
        role_metaroles  => { applied_attribute => [ $role ] },
    );

    return Class::MOP::class_of($for_class);
}

1;

__END__

=for :stopwords GitHub attribute's isa one's rwp SUBTYPING

=for Pod::Coverage init_meta

=head1 SYNOPSIS

    package Some::Class;

    use Moose;
    use MooseX::AttributeShortcuts;

    # same as:
    #   is => 'ro', lazy => 1, builder => '_build_foo'
    has foo => (is => 'lazy');

    # same as: is => 'ro', writer => '_set_foo'
    has foo => (is => 'rwp');

    # same as: is => 'ro', builder => '_build_bar'
    has bar => (is => 'ro', builder => 1);

    # same as: is => 'ro', clearer => 'clear_bar'
    has bar => (is => 'ro', clearer => 1);

    # same as: is => 'ro', predicate => 'has_bar'
    has bar => (is => 'ro', predicate => 1);

    # works as you'd expect for "private": predicate => '_has_bar'
    has _bar => (is => 'ro', predicate => 1);

    # extending? Use the "Shortcuts" trait alias
    extends 'Some::OtherClass';
    has '+bar' => (traits => [Shortcuts], builder => 1, ...);

    # or...
    package Some::Other::Class;

    use Moose;
    use MooseX::AttributeShortcuts -writer_prefix => '_';

    # same as: is => 'ro', writer => '_foo'
    has foo => (is => 'rwp');

=head1 DESCRIPTION

Ever find yourself repeatedly specifying writers and builders, because there's
no good shortcut to specifying them?  Sometimes you want an attribute to have
a read-only public interface, but a private writer.  And wouldn't it be easier
to just say "builder => 1" and have the attribute construct the canonical
"_build_$name" builder name for you?

This package causes an attribute trait to be applied to all attributes defined
to the using class.  This trait extends the attribute option processing to
handle the above variations.

=head1 USAGE

This package automatically applies an attribute metaclass trait.  Unless you
want to change the defaults, you can ignore the talk about "prefixes" below.

=head1 EXTENDING A CLASS

If you're extending a class and trying to extend its attributes as well,
you'll find out that the trait is only applied to attributes defined locally
in the class.  This package exports a trait shortcut function "Shortcuts" that
will help you apply this to the extended attribute:

    has '+something' => (traits => [Shortcuts], ...);

=head1 PREFIXES

We accept two parameters on the use of this module; they impact how builders
and writers are named.

=head2 -writer_prefix

    use MooseX::::AttributeShortcuts -writer_prefix => 'prefix';

The default writer prefix is '_set_'.  If you'd prefer it to be something
else (say, '_'), this is where you'd do that.

=head2 -builder_prefix

    use MooseX::::AttributeShortcuts -builder_prefix => 'prefix';

The default builder prefix is '_build_', as this is what lazy_build does, and
what people in general recognize as build methods.

=head1 NEW ATTRIBUTE OPTIONS

Unless specified here, all options defined by L<Moose::Meta::Attribute> and
L<Class::MOP::Attribute> remain unchanged.

Want to see additional options?  Ask, or better yet, fork on GitHub and send
a pull request. If the shortcuts you're asking for already exist in L<Moo> or
L<Mouse> or elsewhere, please note that as it will carry significant weight.

For the following, "$name" should be read as the attribute name; and the
various prefixes should be read using the defaults.

=head2 is => 'rwp'

Specifying C<is =E<gt> 'rwp'> will cause the following options to be set:

    is     => 'ro'
    writer => "_set_$name"

rwp can be read as "read + write private".

=head2 is => 'lazy'

Specifying C<is =E<gt> 'lazy'> will cause the following options to be set:

    is       => 'ro'
    builder  => "_build_$name"
    lazy     => 1

B<NOTE:> Since 0.009 we no longer set C<init_arg =E<gt> undef> if no C<init_arg>
is explicitly provided.  This is a change made in parallel with L<Moo>, based
on a large number of people surprised that lazy also made one's C<init_def>
undefined.

=head2 is => 'lazy', default => ...

Specifying C<is =E<gt> 'lazy'> and a default will cause the following options to be
set:

    is       => 'ro'
    lazy     => 1
    default  => ... # as provided

That is, if you specify C<is =E<gt> 'lazy'> and also provide a C<default>, then
we won't try to set a builder, as well.

=head2 builder => 1

Specifying C<builder =E<gt> 1> will cause the following options to be set:

    builder => "_build_$name"

=head2 clearer => 1

Specifying C<clearer =E<gt> 1> will cause the following options to be set:

    clearer => "clear_$name"

or, if your attribute name begins with an underscore:

    clearer => "_clear$name"

(that is, an attribute named "_foo" would get "_clear_foo")

=head2 predicate => 1

Specifying C<predicate =E<gt> 1> will cause the following options to be set:

    predicate => "has_$name"

or, if your attribute name begins with an underscore:

    predicate => "_has_$name"

(that is, an attribute named "_foo" would get "_has_foo")

=head2 trigger => 1

Specifying C<trigger =E<gt> 1> will cause the attribute to be created with a trigger
that calls a named method in the class with the options passed to the trigger.
By default, the method name the trigger calls is the name of the attribute
prefixed with "_trigger_".

e.g., for an attribute named "foo" this would be equivalent to:

    trigger => sub { shift->_trigger_foo(@_) }

For an attribute named "_foo":

    trigger => sub { shift->_trigger__foo(@_) }

This naming scheme, in which the trigger is always private, is the same as the
builder naming scheme (just with a different prefix).

=head2 builder => sub { ... }

Passing a coderef to builder will cause that coderef to be installed in the
class this attribute is associated with the name you'd expect, and
C<builder =E<gt> 1> to be set.

e.g., in your class,

    has foo => (is => 'ro', builder => sub { 'bar!' });

...is effectively the same as...

    has foo => (is => 'ro', builder => '_build_foo');
    sub _build_foo { 'bar!' }

=head2 isa => ..., constraint => sub { ... }

Specifying the constraint option with a coderef will cause a new subtype
constraint to be created, with the parent type being the type specified in the
C<isa> option and the constraint being the coderef supplied here.

For example, only integers greater than 10 will pass this attribute's type
constraint:

    # value must be an integer greater than 10 to pass the constraint
    has thinger => (
        isa        => 'Int',
        constraint => sub { $_ > 10 },
        # ...
    );

Note that if you supply a constraint, you must also provide an C<isa>.

=head2 isa => ..., constraint => sub { ... }, coerce => 1

Supplying a constraint and asking for coercion will "Just Work", that is, any
coercions that the C<isa> type has will still work.

For example, let's say that you're using the C<File> type constraint from
L<MooseX::Types::Path::Class>, and you want an additional constraint that the
file must exist:

    has thinger => (
        is         => 'ro',
        isa        => File,
        constraint => sub { !! $_->stat },
        coerce     => 1,
    );

C<thinger> will correctly coerce the string "/etc/passwd" to a
C<Path::Class:File>, and will only accept the coerced result as a value if
the file exists.

=head2 coerce => { Type => sub { ...coerce... }, ... }

Specifying the coerce option with a hashref will cause a new subtype to be
created and used (just as with the constraint option, above), with the
specified coercions added to the list.  In the passed hashref, the keys are
Moose types (well, strings resolvable to Moose types), and the values are
coderefs that will coerce a given type to our type.

    has bar => (
        is     => 'ro',
        isa    => 'Str',
        coerce => {
            Int    => sub { "$_"                       },
            Object => sub { 'An instance of ' . ref $_ },
        },
    );

=head1 ANONYMOUS SUBTYPING AND COERCION

Note that we create new, anonymous subtypes whenever the constraint or
coercion options are specified in such a way that the Shortcuts trait (this
one) is invoked.  It's fully supported to use both constraint and coerce
options at the same time.

This facility is intended to assist with one-off type constraints and
coercions.  It is not possible to deliberately reuse the subtypes we create,
and if you find yourself using a particular isa / constraint / coerce option
triplet in more than one place you should really think about creating a type
that you can reuse.  L<MooseX::Types> provides the facilities to easily do
this.

=head1 SEE ALSO

L<MooseX::CoercePerAttribute> provides our subtype coercion support

=cut
